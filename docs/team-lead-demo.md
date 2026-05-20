# Dev Team Lead Demo Runbook

Goal: show that OpenSearch ISM can replace the old Curator archive flow for retention management, while keeping old data searchable through searchable snapshots.

## 1. Start

Run on `docker-os-cls` from the repo root:

```bash
cp .env.example .env
./scripts/poc-up.sh
./scripts/bootstrap-lifecycle.sh
```

Expected simple output:

```text
PoC stack started.
OpenSearch: http://localhost:9200
Dashboard:  http://localhost:9205
MinIO:      http://localhost:9001

Lifecycle bootstrap complete.
nodes=3 status=green
policy=events-hot-cold-snapshot-10-10
repository=dataskope_lifecycle_repo verified
```

## 2. Check Real Dump Capacity

```bash
./scripts/preflight-real-dump.sh 2025-12-01 2026-01-30
```

Read these lines:

```text
summary.files=61
summary.missing=0
summary.hot_days=10
summary.cold_days=10
summary.raw_bytes=...
summary.hot_files=10
summary.hot_raw_bytes=...
summary.cold_files=10
summary.cold_raw_bytes=...
summary.searchable_snapshot_files=41
summary.searchable_snapshot_raw_bytes=...
estimate.local_cluster_with_headroom_bytes=...
estimate.snapshot_repo_bytes=...
df.root=...
df.data=...
```

Meaning:

- `summary.missing=0`: all expected days exist.
- `hot_raw_bytes`: last 10 days.
- `cold_raw_bytes`: previous 10 days.
- `searchable_snapshot_raw_bytes`: older days that should move to MinIO-backed searchable snapshot.
- `df.root`: local OpenSearch disk headroom.
- `df.data`: MinIO snapshot repository disk headroom.

## 3. Smoke Ingest

Use the smallest real day first:

```bash
BUILD_EVENT_PRODUCER=false ./scripts/remote-run-dump-replay.sh /events_2025_12_07.data.json 1000 50000 events
./scripts/poc-status.sh
```

Expected status shape:

```text
== Retention summary ==
stage                    indexes           docs          store
hot                            1         50,000      ...

== Container resources ==
NAME                  CPU %     MEM USAGE / LIMIT
opensearch-hot        ...
opensearch-cold       ...
opensearch-search     ...
dataskope-minio       ...
```

## 4. Full Replay

For historical data, use the managed replay. It writes one daily file, starts lifecycle, waits for the expected retention stage, then moves to the next day:

```bash
./scripts/run-real-retention-managed-ingest.sh 2025-12-01 2025-12-31 5000
./scripts/poc-status.sh
./scripts/summarize-retention-metrics.sh artifacts/resource-metrics/<metrics-file>.csv
```

Dashboard:

```text
http://docker-os-cls:9205
```

Show these screens:

- Cluster health
- Retention layout: hot / cold / searchable_snapshot
- Safe search runner
- EPS calculator

## 5. What To Say

- Writer creates daily `events_yyyy_MM_dd` indexes and sets `index.creation_date` from the index name.
- Writer does not know ISM policy.
- ISM owns retention: hot -> cold -> snapshot -> searchable snapshot.
- MinIO represents the production S3-compatible snapshot repository.
- Curator archive/restore logic is replaced by ISM policy plus snapshot repository.
- Hot data is fully local and fastest.
- Cold data is local, read-only, force-merged, and searchable.
- Searchable snapshot data is stored mainly in MinIO and remains searchable with a local cache.

## OpenSearch 3.6 Note

In OpenSearch/index-management `3.6.0.0`, `convert_index_to_remote` validation checks whether the source managed index exists before restore and can incorrectly fail with `Index already exists`.

The PoC disables ISM action validation in bootstrap and relies on the native restore step. Use `docs/real-dump-smoke-2026-05-20.md` as the evidence note.
