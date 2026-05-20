#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$IndexPrefix = "events",
    [int]$StopAfterEvents = 1500,
    [int]$EventsPerSecond = 300,
    [switch]$SkipProducer
)

$ErrorActionPreference = "Stop"

Write-Host "Starting MinIO, OpenSearch hot/cold/warm nodes, Dashboards, retention dashboard, and ISM reconciler..."
docker compose up -d --build minio minio-init opensearch-hot opensearch-cold opensearch-search opensearch-dashboards retention-dashboard ism-policy-reconciler

& "$PSScriptRoot\bootstrap-lifecycle.ps1"

if (-not $SkipProducer) {
    Write-Host "Indexing a bounded event batch: IndexPrefix=$IndexPrefix StopAfterEvents=$StopAfterEvents EventsPerSecond=$EventsPerSecond"
    docker compose build event-producer
    docker compose run --rm --no-deps `
        -e OpenSearchSettings__IndexPrefix="$IndexPrefix" `
        -e Producer__StopAfterEvents="$StopAfterEvents" `
        -e Producer__EventsPerSecond="$EventsPerSecond" `
        event-producer
}

Write-Host ""
Write-Host "PoC stack is up."
Write-Host "OpenSearch: http://localhost:9200"
Write-Host "Dashboards: http://localhost:5601"
Write-Host "Retention dashboard: http://localhost:9205"
Write-Host "MinIO console: http://localhost:9001"
Write-Host "Use scripts\lifecycle-explain.ps1 and scripts\test-cold-search.ps1 to observe lifecycle progress."
