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
INGEST_MODE=bulk BULK_WORKERS=6 BULK_BATCH_DOCS=5000 ./scripts/run-real-retention-managed-ingest.sh 2025-12-01 2025-12-31 5000
./scripts/poc-status.sh
./scripts/summarize-retention-metrics.sh artifacts/resource-metrics/<metrics-file>.csv
```

For a small, explainable December demo with real index dates and `3 hot + 3 cold + 3 searchable snapshot`, generate a window policy first:

```bash
python3 scripts/make-window-policy.py --from-date 2025-12-01 --to-date 2025-12-09 --hot-days 3 --cold-days 3 --out opensearch/lifecycle/dataskope-ism-policy.window.poc.json

ISM_POLICY_ID=events-window-3-3-3 ISM_POLICY_FILE=opensearch/lifecycle/dataskope-ism-policy.window.poc.json ./scripts/bootstrap-lifecycle.sh

ISM_POLICY_ID=events-window-3-3-3 INGEST_MODE=bulk BULK_WORKERS=6 BULK_BATCH_DOCS=5000 HOT_AFTER_DAYS=<printed> SNAPSHOT_AFTER_DAYS=<printed> ./scripts/run-real-retention-managed-ingest.sh 2025-12-01 2025-12-09 5000
```

Use the fresh `HOT_AFTER_DAYS` and `SNAPSHOT_AFTER_DAYS` printed by `make-window-policy.py`; they depend on the current date because this is a historical-window PoC.

Known good 2026-05-21 result: 9 days, 99,862,203 docs, 180.50 GiB raw, 46.76 GiB all-hot logical store, 40.51 GiB final logical store, 12.64 GiB MinIO snapshot repository. Evidence: `docs/real-dump-window-3-3-3-2026-05-21.md`.

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
- Real Dataskope Sysmon data needs `index.mapping.total_fields.limit=5000`; the default `1000` rejected valid events on Dec08.

## OpenSearch 3.6 Note

In OpenSearch/index-management `3.6.0.0`, `convert_index_to_remote` validation checks whether the source managed index exists before restore and can incorrectly fail with `Index already exists`.

The PoC disables ISM action validation in bootstrap and relies on the native restore step. The policy also sets `temp=frozen` before convert and then runs an explicit `delete` action, because 3.6.0 does not accept `ignore_index_settings` and did not delete the source automatically in the real dump run. Use `docs/real-dump-smoke-2026-05-20.md`, `docs/real-dump-window-3-3-3-2026-05-20.md`, and `docs/real-dump-window-3-3-3-2026-05-21.md` as the evidence notes.
