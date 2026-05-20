Set-StrictMode -Version 2.0

function Get-OsBaseUrl {
    param(
        [string]$BaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        if ([string]::IsNullOrWhiteSpace($env:OPENSEARCH_URL)) {
            return "http://localhost:9200"
        }

        return $env:OPENSEARCH_URL
    }

    return $BaseUrl.TrimEnd("/")
}

function Join-OsUri {
    param(
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path.StartsWith("http://") -or $Path.StartsWith("https://")) {
        return $Path
    }

    $resolvedBaseUrl = Get-OsBaseUrl $BaseUrl
    return "$resolvedBaseUrl/$($Path.TrimStart('/'))"
}

function Read-OsErrorBody {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ErrorRecord
    )

    try {
        $response = $ErrorRecord.Exception.Response
    }
    catch {
        return $ErrorRecord.Exception.Message
    }

    if ($null -eq $response) {
        return $ErrorRecord.Exception.Message
    }

    try {
        $status = ""
        try {
            $statusCode = [int]$response.StatusCode
            $statusDescription = $response.StatusDescription
            $status = "HTTP $statusCode $statusDescription"
        }
        catch {
            $status = $ErrorRecord.Exception.Message
        }

        $stream = $response.GetResponseStream()
        if ($null -eq $stream) {
            return $status
        }

        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($body)) {
            return $status
        }

        return "$status`n$body"
    }
    catch {
        return $ErrorRecord.Exception.Message
    }
}

function Invoke-OsRequest {
    [CmdletBinding()]
    param(
        [ValidateSet("GET", "POST", "PUT", "DELETE")]
        [string]$Method = "GET",

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [object]$Body,

        [string]$BodyPath,

        [string]$BaseUrl,

        [int]$TimeoutSec = 180
    )

    $uri = Join-OsUri -BaseUrl $BaseUrl -Path $Path
    $params = @{
        Method          = $Method
        Uri             = $uri
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }

    if (-not [string]::IsNullOrWhiteSpace($BodyPath)) {
        $params["Body"] = Get-Content -Raw $BodyPath
        $params["ContentType"] = "application/json"
    }
    elseif ($null -ne $Body) {
        if ($Body -is [string]) {
            $params["Body"] = $Body
        }
        else {
            $params["Body"] = $Body | ConvertTo-Json -Depth 100
        }

        $params["ContentType"] = "application/json"
    }

    Write-Host "$Method $uri"

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $body = Read-OsErrorBody $_
        throw "OpenSearch request failed: $Method $uri`n$body"
    }
}

function Invoke-OsText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$BaseUrl,

        [int]$TimeoutSec = 180
    )

    $uri = Join-OsUri -BaseUrl $BaseUrl -Path $Path
    Write-Host "GET $uri"

    try {
        $response = Invoke-WebRequest -Method GET -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSec
        return $response.Content
    }
    catch {
        $body = Read-OsErrorBody $_
        throw "OpenSearch request failed: GET $uri`n$body"
    }
}

function Wait-OpenSearch {
    [CmdletBinding()]
    param(
        [string]$BaseUrl,
        [int]$TimeoutSec = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-OsRequest -Method GET -Path "_cluster/health" -BaseUrl $BaseUrl -TimeoutSec 10
            if ($health.status -eq "green" -or $health.status -eq "yellow") {
                Write-Host "OpenSearch is ready. status=$($health.status)"
                return $health
            }
        }
        catch {
            Write-Host "Waiting for OpenSearch..."
        }

        Start-Sleep -Seconds 5
    }

    throw "OpenSearch did not become ready within $TimeoutSec seconds."
}

function Set-IsmPolicyFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyId,

        [Parameter(Mandatory = $true)]
        [string]$PolicyFile,

        [string]$BaseUrl
    )

    $path = "_plugins/_ism/policies/$PolicyId"
    try {
        $existing = Invoke-OsRequest -Method GET -Path $path -BaseUrl $BaseUrl
        $seqNo = $existing._seq_no
        $primaryTerm = $existing._primary_term
        Invoke-OsRequest -Method PUT -Path "${path}?if_seq_no=$seqNo&if_primary_term=$primaryTerm" -BodyPath $PolicyFile -BaseUrl $BaseUrl
    }
    catch {
        if ($_.Exception.Message -like "*404*" -or $_.ToString() -like "*not_found*") {
            Invoke-OsRequest -Method PUT -Path $path -BodyPath $PolicyFile -BaseUrl $BaseUrl
            return
        }

        throw
    }
}

function Get-LatestDataskopeIndex {
    [CmdletBinding()]
    param(
        [string]$IndexPattern = "events_*",
        [string]$BaseUrl
    )

    $content = Invoke-OsText -Path "_cat/indices/${IndexPattern}?h=index&s=index:desc" -BaseUrl $BaseUrl
    $indexes = $content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($indexes.Count -eq 0) {
        throw "No index matched pattern '$IndexPattern'."
    }

    return $indexes[0]
}

Export-ModuleMember -Function Get-OsBaseUrl, Join-OsUri, Invoke-OsRequest, Invoke-OsText, Wait-OpenSearch, Set-IsmPolicyFromFile, Get-LatestDataskopeIndex
