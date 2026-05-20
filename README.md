# Dataskope OpenSearch Retention PoC

This repository contains the Dataskope PoC for replacing the current Elasticsearch hot + archive snapshot/restore workflow with an OpenSearch ISM-based retention architecture.

The PoC compares two target shapes:

- Hot + searchable snapshot: simpler target for maximizing searchable retention with less local cluster disk.
- Hot + cold + searchable snapshot: keeps a 10-day read-only/force-merged local cold window before searchable snapshots.

Current real-data target:

- Source data: elasticdump files on `docker-os-cls` under `/events_YYYY_MM_DD.data.json`.
- Date range: `events_2025_12_01` through `events_2026_01_30`.
- Retention: 10 days hot, 10 days cold, remaining days searchable snapshot.
- Snapshot repository: MinIO/S3-compatible repository on the separate `/data` disk.
- Dashboard: http://localhost:9205

## Components

- `OpenSearchEventProducer`: .NET 10 writer/replay tool. It can generate test events or stream elasticdump output without loading the whole file into memory.
- `OpenSearchRetentionDashboard`: .NET 10 dashboard for cluster health, retention stages, safe search, and EPS capacity calculation.
- `opensearch/lifecycle`: Dataskope index templates, ISM policies, and snapshot repository definitions.
- `scripts`: bootstrap, ISM management, real dump preflight/replay, searchable snapshot, and measurement helpers.
- `docs`: architecture, search guidance, cheat sheet, and measured PoC reports.

## Quick Start

For the short demo path, use [Dev Team Lead Demo Runbook](docs/team-lead-demo.md).

Copy the environment template and set MinIO values:

```bash
cp .env.example .env
```

For `docker-os-cls`, keep MinIO on the separate disk:

```bash
MINIO_DATA_DIR=/data/minio
MINIO_BUCKET=dataskope-opensearch-snapshots
```

Start the PoC cluster:

```bash
./scripts/poc-up.sh
```

Bootstrap OpenSearch:

```bash
./scripts/bootstrap-lifecycle.sh
./scripts/poc-status.sh
```

Open:

- OpenSearch: http://localhost:9200
- OpenSearch Dashboards: http://localhost:5601
- Retention Dashboard: http://localhost:9205
- MinIO Console: http://localhost:9001

## Real Dump Workflow

Do not start the real dump replay until the elasticdump process is complete.

When the dump is ready, run the preflight on `docker-os-cls`:

```bash
./scripts/preflight-real-dump.sh 2025-12-01 2026-01-30
```

If the preflight storage estimate is acceptable, run a smoke replay:

```bash
BUILD_EVENT_PRODUCER=false ./scripts/remote-run-dump-replay.sh /events_2025_12_01.data.json 5000 100000 events
```

Then run the full date range:

```bash
BUILD_EVENT_PRODUCER=false ./scripts/run-real-retention-ingest.sh 2025-12-01 2026-01-30 5000
```

The replay mode streams elasticdump lines, extracts `_source`, routes by `TimeCreated`, and creates `events_yyyy_MM_dd` with `index.creation_date` set from the index name. The writer does not attach ISM policies; the lifecycle reconciler handles unmanaged backdated indexes.

## Documentation

- [Cheat Sheet](docs/cheatsheet.md)
- [Dev Team Lead Demo Runbook](docs/team-lead-demo.md)
- [Architecture Comparison](docs/architecture-comparison.md)
- [Search Guidelines](docs/search-guidelines.md)
- [Cluster Calculator](docs/calculator.md)
- [Resource Measurement Plan](docs/resource-measurement-plan.md)

## GitHub Hygiene

Large dumps and local runtime output are intentionally ignored:

- `/events_*.data.json`
- `samples/loadtest-*.ndjson`
- `.env`
- `.tools`
- `bin`, `obj`, `.nuget-packages`, `.dotnet-home`
- rejected-event dumps

Commit only the clean PoC package, not real customer-sized data.
