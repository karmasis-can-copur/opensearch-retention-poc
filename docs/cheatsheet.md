# OpenSearch Retention PoC Cheat Sheet

## Start Cluster

```bash
docker compose -f docker-compose.yml -f docker-compose.server.yml up -d --build \
  minio minio-init opensearch-hot opensearch-cold opensearch-search opensearch-dashboards retention-dashboard ism-policy-reconciler
```

## Bootstrap Repository, Template, and ISM

```bash
./scripts/bootstrap-lifecycle.sh
```

Real Dataskope Sysmon data needs the current template setting `index.mapping.total_fields.limit=5000`. Without it, Dec08 real dump data hit OpenSearch's default `1000` field limit.

## Verify MinIO/S3 Repository

```bash
curl -s http://localhost:9200/_snapshot/dataskope_lifecycle_repo
curl -s -XPOST http://localhost:9200/_snapshot/dataskope_lifecycle_repo/_verify
```

## Lifecycle Status

```bash
./scripts/poc-status.sh
curl -s http://localhost:9200/_plugins/_ism/explain/events_2025_12_01
curl -s "http://localhost:9200/_cat/indices/events_*,remote_events_*?v&s=index"
```

Retry a failed managed index:

```bash
curl -s -XPOST "http://localhost:9200/_plugins/_ism/retry/events_2025_12_01"
```

Remove a policy from a source index:

```bash
curl -s -XPOST "http://localhost:9200/_plugins/_ism/remove/events_2025_12_01"
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

Managed retention replay:

```bash
ISM_POLICY_ID=events-window-3-3-3 INGEST_MODE=bulk BULK_WORKERS=6 BULK_BATCH_DOCS=5000 HOT_AFTER_DAYS=<printed> SNAPSHOT_AFTER_DAYS=<printed> ./scripts/run-real-retention-managed-ingest.sh 2025-12-01 2025-12-09 5000
```

## Measurements

```bash
./scripts/poc-status.sh
./scripts/summarize-retention-metrics.sh artifacts/resource-metrics/<metrics-file>.csv
curl -s "http://localhost:9200/_cat/nodes?v&h=name,node.role,heap.percent,ram.percent,cpu,disk.used,disk.avail,disk.percent"
curl -s "http://localhost:9200/_cat/indices/events_*,remote_events_*?v&s=index"
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
