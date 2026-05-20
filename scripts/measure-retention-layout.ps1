#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexPattern = "events_*,remote_events_*",
    [string]$OutputDir,
    [int]$WarmupRuns = 1,
    [int]$SearchRuns = 5
)

$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot "..\artifacts\resource-metrics"
}

function Convert-ToInt64OrZero {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0L
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "-") {
        return 0L
    }

    return [int64]$text
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return $null
    }

    $sorted = $Values | Sort-Object
    $index = [math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    $index = [math]::Max(0, [math]::Min($index, $sorted.Count - 1))
    return [math]::Round([double]$sorted[$index], 2)
}

function Measure-SearchSet {
    param(
        [string]$Name,
        [string[]]$Indexes
    )

    if ($Indexes.Count -eq 0) {
        return $null
    }

    $path = "$(($Indexes | Sort-Object) -join ',')/_search"
    $body = @{
        size = 0
        track_total_hits = $true
        query = @{
            match_all = @{}
        }
    }

    for ($i = 0; $i -lt $WarmupRuns; $i++) {
        Invoke-OsRequest -Method POST -Path $path -BaseUrl $BaseUrl -Body $body | Out-Null
    }

    $runs = @()
    for ($i = 1; $i -le $SearchRuns; $i++) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-OsRequest -Method POST -Path $path -BaseUrl $BaseUrl -Body $body
        $watch.Stop()

        $runs += [pscustomobject]@{
            run = $i
            client_elapsed_ms = [math]::Round($watch.Elapsed.TotalMilliseconds, 2)
            opensearch_took_ms = $response.took
            hits = [int64]$response.hits.total.value
        }
    }

    $latencies = @($runs | ForEach-Object { [double]$_.client_elapsed_ms })
    return [pscustomobject]@{
        name = $Name
        index_count = $Indexes.Count
        runs = $runs
        avg_ms = [math]::Round(($latencies | Measure-Object -Average).Average, 2)
        p95_ms = Get-Percentile -Values $latencies -Percentile 95
        max_ms = [math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2)
        hits = @($runs)[-1].hits
    }
}

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

function Get-IndexSetting {
    param(
        [object]$SettingsResponse,
        [Parameter(Mandatory = $true)]
        [string]$IndexName,
        [Parameter(Mandatory = $true)]
        [string]$SettingName
    )

    $indexEntry = Get-PropertyValue -Object $SettingsResponse -Name $IndexName
    $settings = Get-PropertyValue -Object $indexEntry -Name "settings"
    $value = Get-PropertyValue -Object $settings -Name $SettingName

    if ($null -eq $value) {
        return ""
    }

    return [string]$value
}

function Get-IndexStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IndexName,
        [object]$SettingsResponse
    )

    $allocationTemp = Get-IndexSetting -SettingsResponse $SettingsResponse -IndexName $IndexName -SettingName "index.routing.allocation.require.temp"
    $storeType = Get-IndexSetting -SettingsResponse $SettingsResponse -IndexName $IndexName -SettingName "index.store.type"

    if ($IndexName -like "remote_*" -or $IndexName -like "*-frozen" -or $storeType -eq "remote_snapshot") {
        return "searchable_snapshot"
    }

    if ($allocationTemp -eq "cold") {
        return "cold"
    }

    return "hot"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$rawIndices = Invoke-OsRequest -Method GET -Path "_cat/indices/${IndexPattern}?format=json&bytes=b&h=health,status,index,uuid,pri,rep,docs.count,docs.deleted,store.size,pri.store.size&s=index" -BaseUrl $BaseUrl
$indices = @($rawIndices | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties["index"]
    })

if ($indices.Count -eq 0) {
    throw "No index matched pattern '$IndexPattern'."
}

$settingsPath = "$(($indices | ForEach-Object { $_.index } | Sort-Object) -join ',')/_settings?flat_settings=true&include_defaults=false"
$settingsResponse = Invoke-OsRequest -Method GET -Path $settingsPath -BaseUrl $BaseUrl
$indexRows = @($indices | ForEach-Object {
        $stage = Get-IndexStage -IndexName $_.index -SettingsResponse $settingsResponse
        [pscustomobject]@{
            health = $_.health
            status = $_.status
            index = $_.index
            uuid = $_.uuid
            pri = $_.pri
            rep = $_.rep
            "docs.count" = $_."docs.count"
            "docs.deleted" = $_."docs.deleted"
            "store.size" = $_."store.size"
            "pri.store.size" = $_."pri.store.size"
            stage = $stage
        }
    })

$hotRows = @($indexRows | Where-Object { $_.stage -eq "hot" })
$coldRows = @($indexRows | Where-Object { $_.stage -eq "cold" })
$searchableSnapshotRows = @($indexRows | Where-Object { $_.stage -eq "searchable_snapshot" })

$hotIndexes = @($hotRows | ForEach-Object { $_.index })
$coldIndexes = @($coldRows | ForEach-Object { $_.index })
$searchableSnapshotIndexes = @($searchableSnapshotRows | ForEach-Object { $_.index })

$sets = @(
    [pscustomobject]@{
        name = "hot"
        index_count = $hotRows.Count
        docs = [int64](($hotRows | ForEach-Object { Convert-ToInt64OrZero $_."docs.count" } | Measure-Object -Sum).Sum)
        store_bytes = [int64](($hotRows | ForEach-Object { Convert-ToInt64OrZero $_."store.size" } | Measure-Object -Sum).Sum)
        primary_store_bytes = [int64](($hotRows | ForEach-Object { Convert-ToInt64OrZero $_."pri.store.size" } | Measure-Object -Sum).Sum)
    },
    [pscustomobject]@{
        name = "cold"
        index_count = $coldRows.Count
        docs = [int64](($coldRows | ForEach-Object { Convert-ToInt64OrZero $_."docs.count" } | Measure-Object -Sum).Sum)
        store_bytes = [int64](($coldRows | ForEach-Object { Convert-ToInt64OrZero $_."store.size" } | Measure-Object -Sum).Sum)
        primary_store_bytes = [int64](($coldRows | ForEach-Object { Convert-ToInt64OrZero $_."pri.store.size" } | Measure-Object -Sum).Sum)
    },
    [pscustomobject]@{
        name = "searchable_snapshot"
        index_count = $searchableSnapshotRows.Count
        docs = [int64](($searchableSnapshotRows | ForEach-Object { Convert-ToInt64OrZero $_."docs.count" } | Measure-Object -Sum).Sum)
        store_bytes = [int64](($searchableSnapshotRows | ForEach-Object { Convert-ToInt64OrZero $_."store.size" } | Measure-Object -Sum).Sum)
        primary_store_bytes = [int64](($searchableSnapshotRows | ForEach-Object { Convert-ToInt64OrZero $_."pri.store.size" } | Measure-Object -Sum).Sum)
    }
)

$searchMeasurements = @(
    Measure-SearchSet -Name "hot_all" -Indexes $hotIndexes
    Measure-SearchSet -Name "cold_all" -Indexes $coldIndexes
    Measure-SearchSet -Name "searchable_snapshot_all" -Indexes $searchableSnapshotIndexes
    Measure-SearchSet -Name "all_events" -Indexes @($hotIndexes + $coldIndexes + $searchableSnapshotIndexes)
) | Where-Object { $null -ne $_ }

$catNodes = Invoke-OsRequest -Method GET -Path "_cat/nodes?format=json&h=name,ip,node.role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent" -BaseUrl $BaseUrl
$catAllocation = Invoke-OsRequest -Method GET -Path "_cat/allocation?format=json&bytes=b&h=shards,disk.indices,disk.used,disk.avail,disk.total,disk.percent,node" -BaseUrl $BaseUrl
$clusterHealth = Invoke-OsRequest -Method GET -Path "_cluster/health" -BaseUrl $BaseUrl
$nodesStats = Invoke-OsRequest -Method GET -Path "_nodes/stats/jvm,process,fs,indices?filter_path=nodes.*.name,nodes.*.jvm.mem.heap_used_in_bytes,nodes.*.jvm.mem.heap_committed_in_bytes,nodes.*.jvm.mem.heap_max_in_bytes,nodes.*.process.cpu.percent,nodes.*.fs.total.total_in_bytes,nodes.*.fs.total.available_in_bytes,nodes.*.indices.store.size_in_bytes,nodes.*.indices.segments.memory_in_bytes,nodes.*.indices.query_cache.memory_size_in_bytes,nodes.*.indices.fielddata.memory_size_in_bytes,nodes.*.indices.request_cache.memory_size_in_bytes,nodes.*.indices.indexing.index_total,nodes.*.indices.search.query_total" -BaseUrl $BaseUrl

$measurement = [pscustomobject]@{
    measured_at_utc = (Get-Date).ToUniversalTime().ToString("O")
    index_pattern = $IndexPattern
    sets = $sets
    search_measurements = $searchMeasurements
    indices = $indexRows
    cat_nodes = $catNodes
    cat_allocation = $catAllocation
    cluster_health = $clusterHealth
    nodes_stats = $nodesStats
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$baseFile = Join-Path $OutputDir "$timestamp-retention-layout"
$jsonPath = "$baseFile.json"
$mdPath = "$baseFile.md"
$measurement | ConvertTo-Json -Depth 100 | Set-Content -Path $jsonPath -Encoding UTF8

$setRows = $sets | ForEach-Object {
    "| $($_.name) | $($_.index_count) | $($_.docs) | $($_.store_bytes) | $($_.primary_store_bytes) |"
}

$searchRows = $searchMeasurements | ForEach-Object {
    "| $($_.name) | $($_.index_count) | $($_.hits) | $($_.avg_ms) | $($_.p95_ms) | $($_.max_ms) |"
}

$nodeRows = @($catNodes) | ForEach-Object {
    "| $($_.name) | $($_.'node.role') | $($_.'heap.percent') | $($_.'ram.percent') | $($_.cpu) | $($_.'load_1m') | $($_.'disk.used_percent') |"
}

$indexStageRows = @($indexRows) | ForEach-Object {
    "| $($_.index) | $($_.stage) | $($_.'docs.count') | $($_.'store.size') | $($_.'pri.store.size') |"
}

$markdown = @(
    "# Retention Layout Measurement",
    "",
    "- Measured UTC: $($measurement.measured_at_utc)",
    "- Cluster health: $($clusterHealth.status)",
    "",
    "## Storage Sets",
    "",
    "| Set | Indexes | Docs | Store bytes | Primary store bytes |",
    "|---|---:|---:|---:|---:|",
    ($setRows -join "`n"),
    "",
    "## Search",
    "",
    "| Set | Indexes | Hits | Avg ms | P95 ms | Max ms |",
    "|---|---:|---:|---:|---:|---:|",
    ($searchRows -join "`n"),
    "",
    "## Nodes",
    "",
    "| Node | Role | Heap % | RAM % | CPU % | Load 1m | Disk used % |",
    "|---|---|---:|---:|---:|---:|---:|",
    ($nodeRows -join "`n"),
    "",
    "## Index Stages",
    "",
    "| Index | Stage | Docs | Store bytes | Primary store bytes |",
    "|---|---|---:|---:|---:|",
    ($indexStageRows -join "`n"),
    "",
    "Raw JSON: $jsonPath"
) -join "`n"

$markdown | Set-Content -Path $mdPath -Encoding UTF8

Write-Host "Wrote $jsonPath"
Write-Host "Wrote $mdPath"
$sets
