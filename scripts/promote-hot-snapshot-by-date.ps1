#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*",
    [string]$PolicyId = "events-hot-snapshot",
    [int]$SnapshotAfterDays = 10,
    [datetime]$AsOfDate = (Get-Date)
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

$today = $AsOfDate.Date
$content = Invoke-OsText -Path "_cat/indices/${IndexPattern}?h=index&s=index" -BaseUrl $BaseUrl
$indexes = $content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and $_ -notlike "*-frozen"
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

    if ($ageDays -lt $SnapshotAfterDays) {
        Write-Host "No change for $index. eventDate=$($indexDate.ToString('yyyy-MM-dd')) ageDays=$ageDays"
        continue
    }

    $body = @{
        policy_id = $PolicyId
        state = "snapshot_ready"
    }

    if ($PSCmdlet.ShouldProcess($index, "change ISM policy state to snapshot_ready")) {
        Write-Host "Promoting $index to snapshot_ready. eventDate=$($indexDate.ToString('yyyy-MM-dd')) ageDays=$ageDays"
        Invoke-OsRequest -Method POST -Path "_plugins/_ism/change_policy/$index" -BaseUrl $BaseUrl -Body $body
    }
}
