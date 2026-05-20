#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*",
    [string]$IndexPrefix = "events",
    [string]$PolicyId = "events-hot-snapshot",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

function Get-PropertyValue {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Test-IsManagedByPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IndexName
    )

    $encodedIndex = [uri]::EscapeDataString($IndexName)
    $explain = Invoke-OsRequest -Method GET -Path "_plugins/_ism/explain/$encodedIndex" -BaseUrl $BaseUrl
    $entry = Get-PropertyValue -Object $explain -Name $IndexName
    $policy = Get-PropertyValue -Object $entry -Name "policy_id"

    return -not [string]::IsNullOrWhiteSpace([string]$policy)
}

$dailyIndexRegex = "^$([regex]::Escape($IndexPrefix))_\d{4}_\d{2}_\d{2}$"
$rawIndices = Invoke-OsRequest -Method GET -Path "_cat/indices/${IndexPattern}?format=json&h=index&s=index" -BaseUrl $BaseUrl
$indices = @($rawIndices |
    Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties["index"] } |
    ForEach-Object { [string]$_.index } |
    Where-Object { $_ -match $dailyIndexRegex } |
    Sort-Object -Unique)

$attached = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($indexName in $indices) {
    if (Test-IsManagedByPolicy -IndexName $indexName) {
        $skipped.Add($indexName) | Out-Null
        continue
    }

    if ($DryRun) {
        Write-Host "DRY-RUN would attach policy '$PolicyId' to '$indexName'."
        $attached.Add($indexName) | Out-Null
        continue
    }

    $encodedIndex = [uri]::EscapeDataString($indexName)
    Invoke-OsRequest -Method POST -Path "_plugins/_ism/add/$encodedIndex" -BaseUrl $BaseUrl -Body @{
        policy_id = $PolicyId
    } | Out-Null
    $attached.Add($indexName) | Out-Null
}

$summary = [pscustomobject]@{
    base_url = $BaseUrl
    index_pattern = $IndexPattern
    policy_id = $PolicyId
    matched_daily_indexes = $indices.Count
    attached_count = $attached.Count
    skipped_managed_count = $skipped.Count
    attached = @($attached)
    skipped_managed = @($skipped)
}

$summary | ConvertTo-Json -Depth 20
