#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexName,
    [switch]$AllowNotCold
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

if ([string]::IsNullOrWhiteSpace($IndexName)) {
    $IndexName = Get-LatestDataskopeIndex -BaseUrl $BaseUrl
}

$search = Invoke-OsRequest -Method POST -Path "$IndexName/_search" -BaseUrl $BaseUrl -Body @{
    size = 1
    track_total_hits = $true
    query = @{
        match_all = @{}
    }
}

if ($search.hits.total.value -lt 1) {
    throw "Cold search check failed: $IndexName has no searchable documents."
}

$settings = Invoke-OsRequest -Method GET -Path "$IndexName/_settings" -BaseUrl $BaseUrl
$shards = Invoke-OsText -Path "_cat/shards/${IndexName}?h=index,shard,prirep,state,node" -BaseUrl $BaseUrl

Write-Host "Searchable docs: $($search.hits.total.value)"
Write-Host "Settings:"
$settings
Write-Host "Shards:"
$shards

if (-not $AllowNotCold -and ($shards -notmatch "opensearch-cold")) {
    throw "Cold search check failed: shards for $IndexName are not on opensearch-cold yet."
}

Write-Host "Cold search check passed for $IndexName."
