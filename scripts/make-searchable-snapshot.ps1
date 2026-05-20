#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexName,
    [string]$RepositoryName = "dataskope_lifecycle_repo",
    [string]$SnapshotName,
    [string]$FrozenIndexName,
    [switch]$DeleteOriginalAfterSnapshot,
    [switch]$Force
)

Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

if ([string]::IsNullOrWhiteSpace($IndexName)) {
    $IndexName = Get-LatestDataskopeIndex -BaseUrl $BaseUrl
}

if ([string]::IsNullOrWhiteSpace($SnapshotName)) {
    $SnapshotName = $IndexName
}

if ([string]::IsNullOrWhiteSpace($FrozenIndexName)) {
    if ($DeleteOriginalAfterSnapshot) {
        $FrozenIndexName = $IndexName
    }
    else {
        $FrozenIndexName = "$IndexName-frozen"
    }
}

Invoke-OsRequest -Method POST -Path "$IndexName/_refresh" -BaseUrl $BaseUrl | Out-Null

$snapshotExists = $false
try {
    Invoke-OsRequest -Method GET -Path "_snapshot/$RepositoryName/$SnapshotName" -BaseUrl $BaseUrl | Out-Null
    $snapshotExists = $true
}
catch {
    if ($_.ToString() -notlike "*snapshot_missing_exception*" -and $_.ToString() -notlike "*404*") {
        throw
    }
}

if (-not $snapshotExists) {
    Invoke-OsRequest -Method PUT -Path "_snapshot/$RepositoryName/${SnapshotName}?wait_for_completion=true" -BaseUrl $BaseUrl -Body @{
        indices = $IndexName
        include_global_state = $false
    } | Out-Null
}

if ($DeleteOriginalAfterSnapshot) {
    if (-not $Force) {
        throw "DeleteOriginalAfterSnapshot is destructive. Re-run with -Force after confirming snapshot '$SnapshotName' exists."
    }

    Invoke-OsRequest -Method DELETE -Path $IndexName -BaseUrl $BaseUrl | Out-Null
}
else {
    try {
        Invoke-OsRequest -Method GET -Path $FrozenIndexName -BaseUrl $BaseUrl | Out-Null
        if (-not $Force) {
            throw "Frozen index '$FrozenIndexName' already exists. Re-run with -Force to delete and recreate it."
        }

        Invoke-OsRequest -Method DELETE -Path $FrozenIndexName -BaseUrl $BaseUrl | Out-Null
    }
    catch {
        if ($_.ToString() -notlike "*index_not_found_exception*" -and $_.ToString() -notlike "*404*") {
            throw
        }
    }
}

$restoreBody = @{
    indices = $IndexName
    storage_type = "remote_snapshot"
    include_aliases = $false
    ignore_index_settings = @(
        "index.routing.allocation.require.temp",
        "index.routing.allocation.include.temp",
        "index.routing.allocation.exclude.temp"
    )
    index_settings = @{
        "index.routing.allocation.require.temp" = "frozen"
    }
}

if ($FrozenIndexName -ne $IndexName) {
    $restoreBody["rename_pattern"] = "(.+)"
    $restoreBody["rename_replacement"] = $FrozenIndexName
}

Invoke-OsRequest -Method POST -Path "_snapshot/$RepositoryName/$SnapshotName/_restore?wait_for_completion=true" -BaseUrl $BaseUrl -Body $restoreBody | Out-Null

Write-Host "Searchable snapshot restored as $FrozenIndexName."
Invoke-OsRequest -Method GET -Path "$FrozenIndexName/_settings?filter_path=*.settings.index.store.type" -BaseUrl $BaseUrl
