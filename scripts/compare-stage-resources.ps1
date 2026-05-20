#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$MetricFiles,
    [string]$OutputPath = "$PSScriptRoot\..\artifacts\resource-metrics\comparison-$(Get-Date -Format yyyyMMdd-HHmmss).md"
)

$ErrorActionPreference = "Stop"

$measurements = foreach ($file in $MetricFiles) {
    Get-Content -Raw $file | ConvertFrom-Json
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$rows = foreach ($measurement in $measurements) {
    $queries = @($measurement.search_summary) | ForEach-Object {
        "$($_.query): avg=$($_.avg_ms)ms p95=$($_.p95_ms)ms hits=$($_.last_hits)"
    }

    "| $($measurement.stage) | $($measurement.index) | $($measurement.summary.docs_count) | $($measurement.summary.store_bytes) | $($measurement.summary.primary_store_bytes) | $($measurement.summary.shard_count) | $($measurement.summary.shard_nodes -join ', ') | $($queries -join '<br>') |"
}

$markdown = @"
# Hot/Cold/Frozen Resource Comparison

| Stage | Index | Docs | Store bytes | Primary store bytes | Shards | Shard nodes | Search summary |
|---|---|---:|---:|---:|---:|---|---|
$($rows -join "`n")

Notes:

- CPU and RAM are node-level measurements. Attribute cost to an index by combining shard placement with node metrics and before/after measurements.
- Disk at index level comes from `_cat/indices` and `_stats/store`.
- Searchable snapshot indexes may show much lower local store because data is served from the snapshot repository and cached on search nodes.
"@

$markdown | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Wrote $OutputPath"
