# OpenSearch Retention PoC Cheat Sheet

## Start Cluster

```bash
docker compose -f docker-compose.yml -f docker-compose.server.yml up -d --build \
  minio minio-init opensearch-hot opensearch-cold opensearch-search opensearch-dashboards retention-dashboard ism-policy-reconciler
```

## Bootstrap Repository, Template, and ISM

```powershell
.\scripts\bootstrap-lifecycle.ps1 `
  -BaseUrl http://localhost:9200 `
  -PolicyId events-hot-cold-snapshot-10-10 `
  -PolicyFile .\opensearch\lifecycle\dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json `
  -RepositoryFile .\opensearch\lifecycle\snapshot-repository.s3-minio.json `
  -IndexTemplateFile .\opensearch\lifecycle\dataskope-index-template.loadtest.json `
  -ExpectedNodes 3
```

## Verify MinIO/S3 Repository

```bash
curl -s http://localhost:9200/_snapshot/dataskope_lifecycle_repo
curl -s -XPOST http://localhost:9200/_snapshot/dataskope_lifecycle_repo/_verify
```

## Lifecycle Operations

```powershell
.\scripts\lifecycle-list.ps1 -BaseUrl http://localhost:9200
.\scripts\lifecycle-explain.ps1 -BaseUrl http://localhost:9200 -ShowPolicy -ValidateAction
.\scripts\reconcile-ism-policy.ps1 -BaseUrl http://localhost:9200 -PolicyId events-hot-cold-snapshot-10-10
```

Retry a failed managed index:

```powershell
.\scripts\lifecycle-retry.ps1 -BaseUrl http://localhost:9200 -IndexName events_2026_01_01
```

Remove a policy from a source index:

```powershell
.\scripts\lifecycle-remove-policy.ps1 -BaseUrl http://localhost:9200 -IndexName events_2026_01_01
```

## Real Dump Preflight

Run this only after the elasticdump process is complete.

```bash
./scripts/preflight-real-dump.sh 2025-12-01 2026-01-30
```

Optional line counting is expensive for large files:

```bash
COUNT_LINES=true ./scripts/preflight-real-dump.sh 2025-12-01 2026-01-30
```

## Real Dump Replay

Smoke:

```bash
BUILD_EVENT_PRODUCER=false ./scripts/remote-run-dump-replay.sh /events_2025_12_01.data.json 5000 100000 events
```

Full range:

```bash
BUILD_EVENT_PRODUCER=false ./scripts/run-real-retention-ingest.sh 2025-12-01 2026-01-30 5000
```

## Measurements

Retention layout:

```powershell
.\scripts\measure-retention-layout.ps1 -BaseUrl http://localhost:9200 -IndexPattern 'events_*,remote_events_*'
```

Single stage:

```powershell
.\scripts\measure-index-stage.ps1 -BaseUrl http://localhost:9200 -Stage hot -IndexName events_2026_01_30 -IncludeDocker
```

## Safe Search Examples

Count only:

```bash
curl -s -XPOST http://localhost:9200/events_2026_01_30/_search \
  -H 'content-type: application/json' \
  -d '{"size":0,"track_total_hits":true,"query":{"match_all":{}}}'
```

Date-bounded count:

```bash
curl -s -XPOST http://localhost:9200/events_2026_01_30/_search \
  -H 'content-type: application/json' \
  -d '{"size":0,"track_total_hits":true,"query":{"range":{"TimeCreated":{"gte":"2026-01-30T00:00:00Z","lte":"2026-01-30T23:59:59Z"}}}}'
```

Small aggregation:

```bash
curl -s -XPOST http://localhost:9200/events_2026_01_30/_search \
  -H 'content-type: application/json' \
  -d '{"size":0,"query":{"match_all":{}},"aggs":{"event_ids":{"terms":{"field":"EventID","size":10}}}}'
```
