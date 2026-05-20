#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost:9200",
    [string]$IndexName,
    [string]$Stage = "custom",
    [string]$OutputDir = "$PSScriptRoot\..\artifacts\resource-metrics",
    [int]$WarmupRuns = 1,
    [int]$SearchRuns = 5,
    [switch]$IncludeDocker
)

$ErrorActionPreference = "Stop"
Import-Module "$PSScriptRoot\OpenSearchLifecycle.psm1" -Force

function Convert-ToInt64OrNull {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "-") {
        return $null
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

function Invoke-MeasuredSearch {
    param(
        [string]$Name,
        [hashtable]$Body,
        [int]$Warmups,
        [int]$Runs
    )

    for ($i = 0; $i -lt $Warmups; $i++) {
        Invoke-OsRequest -Method POST -Path "$IndexName/_search" -BaseUrl $BaseUrl -Body $Body | Out-Null
    }

    $results = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-OsRequest -Method POST -Path "$IndexName/_search" -BaseUrl $BaseUrl -Body $Body
        $watch.Stop()

        $totalHits = $null
        if ($null -ne $response.hits -and $null -ne $response.hits.total) {
            if ($null -ne $response.hits.total.value) {
                $totalHits = [int64]$response.hits.total.value
            }
            else {
                $totalHits = [int64]$response.hits.total
            }
        }

        $results += [pscustomobject]@{
            query = $Name
            run = $i
            client_elapsed_ms = [math]::Round($watch.Elapsed.TotalMilliseconds, 2)
            opensearch_took_ms = $response.took
            hits = $totalHits
        }
    }

    return $results
}

if ([string]::IsNullOrWhiteSpace($IndexName)) {
    $IndexName = Get-LatestDataskopeIndex -BaseUrl $BaseUrl
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeIndexName = $IndexName -replace "[^A-Za-z0-9_.-]", "_"
$safeStage = $Stage -replace "[^A-Za-z0-9_.-]", "_"
$baseFile = Join-Path $OutputDir "$timestamp-$safeStage-$safeIndexName"

Write-Host "Measuring index=$IndexName stage=$Stage"

$indexStatsBefore = Invoke-OsRequest -Method GET -Path "$IndexName/_stats?level=shards" -BaseUrl $BaseUrl
$searchQueries = @(
    @{
        name = "match_all_size_10"
        body = @{
            size = 10
            query = @{
                match_all = @{}
            }
        }
    },
    @{
        name = "time_range_all"
        body = @{
            size = 10
            query = @{
                range = @{
                    TimeCreated = @{
                        gte = "1970-01-01T00:00:00Z"
                        lte = "3000-01-01T00:00:00Z"
                    }
                }
            }
        }
    },
    @{
        name = "eventid_range"
        body = @{
            size = 10
            query = @{
                range = @{
                    EventID = @{
                        gte = 0
                    }
                }
            }
        }
    },
    @{
        name = "eventsource_text_match"
        body = @{
            size = 10
            query = @{
                match = @{
                    EventSource = "Microsoft-Windows-Security-Auditing"
                }
            }
        }
    }
)

$searchResults = @()
foreach ($query in $searchQueries) {
    $searchResults += Invoke-MeasuredSearch -Name $query.name -Body $query.body -Warmups $WarmupRuns -Runs $SearchRuns
}

$indexStatsAfter = Invoke-OsRequest -Method GET -Path "$IndexName/_stats?level=shards" -BaseUrl $BaseUrl
$segments = Invoke-OsRequest -Method GET -Path "$IndexName/_segments?verbose=true" -BaseUrl $BaseUrl
$settings = Invoke-OsRequest -Method GET -Path "$IndexName/_settings" -BaseUrl $BaseUrl
$mapping = Invoke-OsRequest -Method GET -Path "$IndexName/_mapping" -BaseUrl $BaseUrl
$catIndices = Invoke-OsRequest -Method GET -Path "_cat/indices/${IndexName}?format=json&bytes=b&h=health,status,index,uuid,pri,rep,docs.count,docs.deleted,store.size,pri.store.size" -BaseUrl $BaseUrl
$catShards = Invoke-OsRequest -Method GET -Path "_cat/shards/${IndexName}?format=json&bytes=b&h=index,shard,prirep,state,docs,store,node,unassigned.reason" -BaseUrl $BaseUrl
$catNodes = Invoke-OsRequest -Method GET -Path "_cat/nodes?format=json&h=name,ip,node.role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent" -BaseUrl $BaseUrl
$catAllocation = Invoke-OsRequest -Method GET -Path "_cat/allocation?format=json&bytes=b&h=shards,disk.indices,disk.used,disk.avail,disk.total,disk.percent,node" -BaseUrl $BaseUrl
$clusterHealth = Invoke-OsRequest -Method GET -Path "_cluster/health/$IndexName" -BaseUrl $BaseUrl
$nodesStats = Invoke-OsRequest -Method GET -Path "_nodes/stats/jvm,process,fs,indices?filter_path=nodes.*.name,nodes.*.jvm.mem.heap_used_in_bytes,nodes.*.jvm.mem.heap_committed_in_bytes,nodes.*.jvm.mem.heap_max_in_bytes,nodes.*.process.cpu.percent,nodes.*.process.mem.total_virtual_in_bytes,nodes.*.fs.total.total_in_bytes,nodes.*.fs.total.free_in_bytes,nodes.*.fs.total.available_in_bytes,nodes.*.indices.store.size_in_bytes,nodes.*.indices.segments.memory_in_bytes,nodes.*.indices.query_cache.memory_size_in_bytes,nodes.*.indices.fielddata.memory_size_in_bytes,nodes.*.indices.request_cache.memory_size_in_bytes,nodes.*.indices.indexing.index_total,nodes.*.indices.search.query_total" -BaseUrl $BaseUrl

$dockerStats = @()
if ($IncludeDocker) {
    try {
        $dockerLines = docker stats --no-stream --format "{{json .}}" opensearch-hot opensearch-cold opensearch-search 2>$null
        foreach ($line in $dockerLines) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $dockerStats += $line | ConvertFrom-Json
            }
        }
    }
    catch {
        $dockerStats = @([pscustomobject]@{ error = $_.Exception.Message })
    }
}

$indexRow = @($catIndices)[0]
$storeBytes = Convert-ToInt64OrNull $indexRow."store.size"
$primaryStoreBytes = Convert-ToInt64OrNull $indexRow."pri.store.size"
$docsCount = Convert-ToInt64OrNull $indexRow."docs.count"

$searchSummary = @()
foreach ($group in ($searchResults | Group-Object query)) {
    $latencies = @($group.Group | ForEach-Object { [double]$_.client_elapsed_ms })
    $searchSummary += [pscustomobject]@{
        query = $group.Name
        runs = $group.Count
        min_ms = [math]::Round(($latencies | Measure-Object -Minimum).Minimum, 2)
        avg_ms = [math]::Round(($latencies | Measure-Object -Average).Average, 2)
        p50_ms = Get-Percentile -Values $latencies -Percentile 50
        p95_ms = Get-Percentile -Values $latencies -Percentile 95
        max_ms = [math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2)
        last_hits = @($group.Group)[-1].hits
    }
}

$measurement = [pscustomobject]@{
    measured_at_utc = (Get-Date).ToUniversalTime().ToString("O")
    stage = $Stage
    index = $IndexName
    summary = [pscustomobject]@{
        docs_count = $docsCount
        store_bytes = $storeBytes
        primary_store_bytes = $primaryStoreBytes
        shard_count = @($catShards).Count
        shard_nodes = @($catShards | Select-Object -ExpandProperty node -Unique)
    }
    search_summary = $searchSummary
    search_results = $searchResults
    cat_indices = $catIndices
    cat_shards = $catShards
    cat_nodes = $catNodes
    cat_allocation = $catAllocation
    cluster_health = $clusterHealth
    index_stats_before_search = $indexStatsBefore
    index_stats_after_search = $indexStatsAfter
    segments = $segments
    settings = $settings
    mapping = $mapping
    nodes_stats = $nodesStats
    docker_stats = $dockerStats
}

$jsonPath = "$baseFile.json"
$mdPath = "$baseFile.md"
$measurement | ConvertTo-Json -Depth 100 | Set-Content -Path $jsonPath -Encoding UTF8

$stageRows = $searchSummary | ForEach-Object {
    "| $($_.query) | $($_.runs) | $($_.avg_ms) | $($_.p50_ms) | $($_.p95_ms) | $($_.last_hits) |"
}

$shardRows = @($catShards) | ForEach-Object {
    "| $($_.shard) | $($_.prirep) | $($_.state) | $($_.docs) | $($_.store) | $($_.node) |"
}

$nodeRows = @($catNodes) | ForEach-Object {
    "| $($_.name) | $($_.'node.role') | $($_.'heap.percent') | $($_.'ram.percent') | $($_.cpu) | $($_.'load_1m') | $($_.'disk.used_percent') |"
}

$markdownLines = @(
    "# Resource Measurement",
    "",
    "- Stage: $Stage",
    "- Index: $IndexName",
    "- Measured UTC: $($measurement.measured_at_utc)",
    "- Docs: $docsCount",
    "- Store bytes: $storeBytes",
    "- Primary store bytes: $primaryStoreBytes",
    "- Shard nodes: $($measurement.summary.shard_nodes -join ', ')",
    "",
    "## Search",
    "",
    "| Query | Runs | Avg ms | P50 ms | P95 ms | Last hits |",
    "|---|---:|---:|---:|---:|---:|",
    ($stageRows -join "`n"),
    "",
    "## Shards",
    "",
    "| Shard | P/R | State | Docs | Store bytes | Node |",
    "|---:|---|---|---:|---:|---|",
    ($shardRows -join "`n"),
    "",
    "## Nodes",
    "",
    "| Node | Role | Heap % | RAM % | CPU % | Load 1m | Disk used % |",
    "|---|---|---:|---:|---:|---:|---:|",
    ($nodeRows -join "`n"),
    "",
    "Raw JSON: $jsonPath"
)
$markdown = $markdownLines -join "`n"

$markdown | Set-Content -Path $mdPath -Encoding UTF8

Write-Host "Wrote $jsonPath"
Write-Host "Wrote $mdPath"
$measurement.summary
