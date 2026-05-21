# Real Dump Window PoC: 3 Hot + 3 Cold + 3 Searchable Snapshot

Date: 2026-05-20  
Server: `docker-os-cls` / `192.168.1.36`  
Dataset: `/events_2025_12_23.data.json` through `/events_2025_12_31.data.json`

## Goal

Use real December dump data without remapping index dates. The policy thresholds are calculated against the real `index.creation_date` values so the final layout becomes:

- Searchable snapshot: `2025-12-23` through `2025-12-25`
- Cold: `2025-12-26` through `2025-12-28`
- Hot: `2025-12-29` through `2025-12-31`

## Commands

```bash
python3 scripts/make-window-policy.py \
  --from-date 2025-12-23 \
  --to-date 2025-12-31 \
  --hot-days 3 \
  --cold-days 3 \
  --out opensearch/lifecycle/dataskope-ism-policy.window.poc.json

ISM_POLICY_ID=events-window-3-3-3 \
ISM_POLICY_FILE=opensearch/lifecycle/dataskope-ism-policy.window.poc.json \
./scripts/bootstrap-lifecycle.sh

INGEST_MODE=bulk \
BULK_WORKERS=8 \
BULK_BATCH_DOCS=10000 \
HOT_AFTER_DAYS=143 \
SNAPSHOT_AFTER_DAYS=146 \
METRICS_FILE=artifacts/resource-metrics/dec-3-3-3-20260520140607.csv \
./scripts/run-real-retention-managed-ingest.sh 2025-12-23 2025-12-31 5000
```

Generated thresholds on 2026-05-20:

```text
HOT_AFTER_DAYS=143
SNAPSHOT_AFTER_DAYS=146
COLD_DAYS=3
```

If this is rerun later, use the new `HOT_AFTER_DAYS` and `SNAPSHOT_AFTER_DAYS` printed by `make-window-policy.py`.

## Result

```text
days=9 docs=8,139,975 raw=13.02 GiB
all_hot_logical_store=6.06 GiB
final_local_logical_store=5.91 GiB
snapshot_repository_size=2.35 GiB
root_free_after=176.51 GiB
data_free_after=230.15 GiB

stage,days,docs,logical_store
cold,3,2,467,243,1.70 GiB
hot,3,2,383,625,1.86 GiB
searchable_snapshot,3,3,289,107,2.35 GiB
```

Final index placement:

```text
remote_events_2025_12_23 -> opensearch-search
remote_events_2025_12_24 -> opensearch-search
remote_events_2025_12_25 -> opensearch-search
events_2025_12_26        -> opensearch-cold
events_2025_12_27        -> opensearch-cold
events_2025_12_28        -> opensearch-cold
events_2025_12_29        -> opensearch-hot
events_2025_12_30        -> opensearch-hot
events_2025_12_31        -> opensearch-hot
```

## Critical OpenSearch 3.6 Findings

- `convert_index_to_remote` in index-management `3.6.0.0` supports only `repository`, `snapshot`, and `rename_pattern`. It rejects `ignore_index_settings` and `number_of_replicas`.
- If a source index carries `index.routing.allocation.require.temp=cold`, the restored remote snapshot can inherit it and stay unassigned. The native workaround is to set `allocation require temp=frozen` inside `snapshot_ready` before snapshot/convert.
- In this version, `convert_index_to_remote` completed restore but did not delete the source index. The policy now adds an explicit native `delete` action after `convert_index_to_remote`.
- Backfilled indexes older than the snapshot threshold should transition from `hot` directly to `snapshot_ready` before the `cold` transition. The generated window policy orders hot transitions as `snapshot_ready` first, then `cold`.

## Notes

The first day, `events_2025_12_23`, was manually source-deleted after validating the remote index because the run had already started before the explicit `delete` action was added. `events_2025_12_24` and later used the updated native policy path.
