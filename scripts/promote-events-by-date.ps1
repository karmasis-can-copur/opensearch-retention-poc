#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*",
    [string]$PolicyId = "events-hot-cold",
    [int]$ColdAfterDays = 2,
    [int]$SnapshotAfterDays = 30,
    [datetime]$AsOfDate = (Get-Date)
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

$today = $AsOfDate.Date
$content = Invoke-OsText -Path "_cat/indices/${IndexPattern}?h=index&s=index" -BaseUrl $BaseUrl
$indexes = $content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $_ -notlike "*-frozen"
}

if ($indexes.Count -eq 0) {
    Write-Host "No indexes matched $IndexPattern."
    return
}

foreach ($index in $indexes) {
    $match = [regex]::Match($index, "^(?<prefix>.+)_(?<year>\d{4})_(?<month>\d{2})_(?<day>\d{2})(?:_.+)?$")
    if (-not $match.Success) {
        Write-Host "Skipping $index because it does not match events_yyyy_MM_dd."
        continue
    }

    $indexDate = [datetime]::new(
        [int]$match.Groups["year"].Value,
        [int]$match.Groups["month"].Value,
        [int]$match.Groups["day"].Value)
    $ageDays = [int]($today - $indexDate.Date).TotalDays

    if ($ageDays -lt 0) {
        Write-Host "Skipping future-dated index $index. indexDate=$($indexDate.ToString('yyyy-MM-dd'))"
        continue
    }

    $state = "<unmanaged>"
    try {
        $explain = Invoke-OsRequest -Method GET -Path "_plugins/_ism/explain/$index" -BaseUrl $BaseUrl
        $managed = $explain.PSObject.Properties[$index].Value
        if ($null -ne $managed -and $null -ne $managed.state) {
            $state = $managed.state.name
        }
    }
    catch {
        Write-Host "Could not read ISM state for $index. $($_.Exception.Message)"
    }

    $targetState = $null
    if ($ageDays -ge $SnapshotAfterDays -and $state -eq "cold") {
        $targetState = "snapshot_ready"
    }
    elseif ($ageDays -ge $ColdAfterDays -and $state -ne "cold" -and $state -ne "snapshot_ready") {
        $targetState = "cold"
    }

    if ([string]::IsNullOrWhiteSpace($targetState)) {
        Write-Host "No change for $index. eventDate=$($indexDate.ToString('yyyy-MM-dd')) ageDays=$ageDays state=$state"
        continue
    }

    $body = @{
        policy_id = $PolicyId
        state = $targetState
    }

    if ($PSCmdlet.ShouldProcess($index, "change ISM policy state to $targetState")) {
        Write-Host "Promoting $index to $targetState. eventDate=$($indexDate.ToString('yyyy-MM-dd')) ageDays=$ageDays currentState=$state"
        Invoke-OsRequest -Method POST -Path "_plugins/_ism/change_policy/$index" -BaseUrl $BaseUrl -Body $body
    }
}
