#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$FrozenIndexName
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

if ([string]::IsNullOrWhiteSpace($FrozenIndexName)) {
    $FrozenIndexName = Get-LatestDataskopeIndex -IndexPattern "events_*-frozen" -BaseUrl $BaseUrl
}

$settings = Invoke-OsRequest -Method GET -Path "$FrozenIndexName/_settings" -BaseUrl $BaseUrl
$settingsText = $settings | ConvertTo-Json -Depth 20
if ($settingsText -notmatch "remote_snapshot") {
    throw "Frozen search check failed: $FrozenIndexName is not a remote_snapshot index."
}

$search = Invoke-OsRequest -Method POST -Path "$FrozenIndexName/_search" -BaseUrl $BaseUrl -Body @{
    size = 1
    track_total_hits = $true
    query = @{
        match_all = @{}
    }
}

if ($search.hits.total.value -lt 1) {
    throw "Frozen search check failed: $FrozenIndexName has no searchable documents."
}

Write-Host "Frozen searchable docs: $($search.hits.total.value)"
Write-Host "Settings:"
$settings
Write-Host "Frozen search check passed for $FrozenIndexName."
