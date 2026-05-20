#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [Parameter(Mandatory = $true)]
    [string]$IndexName,
    [string]$RepositoryName = "dataskope_lifecycle_repo",
    [string]$SnapshotName,
    [string]$FrozenIndexName,
    [switch]$DeleteOriginalAfterValidation,
    [switch]$Force
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

if ([string]::IsNullOrWhiteSpace($FrozenIndexName)) {
    $FrozenIndexName = "$IndexName-frozen"
}

if ([string]::IsNullOrWhiteSpace($SnapshotName)) {
    $snapshots = Invoke-OsRequest -Method GET -Path "_snapshot/$RepositoryName/_all?verbose=false" -BaseUrl $BaseUrl
    $matches = @($snapshots.snapshots | Where-Object {
        $_.state -eq "SUCCESS" -and @($_.indices) -contains $IndexName
    } | Sort-Object -Property snapshot -Descending)

    if ($matches.Count -eq 0) {
        throw "No SUCCESS snapshot found for index '$IndexName' in repository '$RepositoryName'."
    }

    $SnapshotName = $matches[0].snapshot
}

try {
    Invoke-OsRequest -Method GET -Path $FrozenIndexName -BaseUrl $BaseUrl | Out-Null
    if (-not $Force) {
        throw "Frozen index '$FrozenIndexName' already exists. Re-run with -Force to recreate."
    }

    Invoke-OsRequest -Method DELETE -Path $FrozenIndexName -BaseUrl $BaseUrl | Out-Null
}
catch {
    if ($_.ToString() -notlike "*index_not_found_exception*" -and $_.ToString() -notlike "*404*") {
        throw
    }
}

$restoreBody = @{
    indices = $IndexName
    storage_type = "remote_snapshot"
    include_aliases = $false
    ignore_index_settings = @(
        "index.routing.allocation.require.temp",
        "index.routing.allocation.include.temp",
        "index.routing.allocation.exclude.temp",
        "index.blocks.write",
        "index.blocks.read_only",
        "index.plugins.index_state_management.policy_id",
        "index.opendistro.index_state_management.policy_id",
        "plugins.index_state_management.policy_id",
        "opendistro.index_state_management.policy_id"
    )
    index_settings = @{
        "index.routing.allocation.require.temp" = "frozen"
    }
    rename_pattern = "(.+)"
    rename_replacement = $FrozenIndexName
}

Invoke-OsRequest -Method POST -Path "_snapshot/$RepositoryName/$SnapshotName/_restore?wait_for_completion=true" -BaseUrl $BaseUrl -Body $restoreBody | Out-Null

$settings = Invoke-OsRequest -Method GET -Path "$FrozenIndexName/_settings" -BaseUrl $BaseUrl
$settingsText = $settings | ConvertTo-Json -Depth 50
if ($settingsText -notmatch "remote_snapshot") {
    throw "Restore validation failed: '$FrozenIndexName' is not remote_snapshot."
}

$explain = Invoke-OsRequest -Method GET -Path "_plugins/_ism/explain/$FrozenIndexName" -BaseUrl $BaseUrl
$managed = $false
if ($null -ne $explain.PSObject.Properties[$FrozenIndexName] -and
    $null -ne $explain.$FrozenIndexName.policy_id) {
    $managed = $true
}

if ($managed) {
    throw "Restore validation failed: '$FrozenIndexName' is managed by ISM policy '$($explain.$FrozenIndexName.policy_id)'. Frozen searchable snapshot indexes must stay outside ISM."
}

$search = Invoke-OsRequest -Method POST -Path "$FrozenIndexName/_search" -BaseUrl $BaseUrl -Body @{
    size = 0
    track_total_hits = $true
    query = @{
        match_all = @{}
    }
}

if ($search.hits.total.value -lt 1) {
    throw "Restore validation failed: '$FrozenIndexName' returned no documents."
}

if ($DeleteOriginalAfterValidation) {
    Invoke-OsRequest -Method DELETE -Path $IndexName -BaseUrl $BaseUrl | Out-Null
    Write-Host "Deleted original index after searchable snapshot validation: $IndexName"
}

Write-Host "Searchable snapshot ready. source=$IndexName frozen=$FrozenIndexName snapshot=$SnapshotName docs=$($search.hits.total.value)"
