# Real Dump Window PoC: 2025-12-01..09

## Scope

- Range: `2025-12-01` through `2025-12-09`
- Layout: `3 searchable snapshot + 3 cold + 3 hot`
- Indexes: `events_yyyy_MM_dd`, 1 primary shard, 0 replicas
- Template: Dataskope mapping, `index.codec=best_compression`, `index.mapping.total_fields.limit=5000`
- Repository: MinIO/S3, bucket `dataskope-opensearch-snapshots`

## Result

```text
days=9 docs=99,862,203 raw=180.50 GiB
all_hot_logical_store=46.76 GiB
final_local_logical_store=40.51 GiB
snapshot_repository_size=12.64 GiB
root_free_after=155.57 GiB
data_free_after=219.86 GiB
```

```text
stage                    days            docs      logical_store
searchable_snapshot         3      32,249,263          12.64 GiB
cold                        3      47,109,218          18.25 GiB
hot                         3      20,503,722           9.62 GiB
```

Final index layout:

```text
remote_events_2025_12_01    searchable_snapshot    13,011,615    5.1gb
remote_events_2025_12_02    searchable_snapshot    12,827,771      5gb
remote_events_2025_12_03    searchable_snapshot     6,409,877    2.4gb
events_2025_12_04           cold                   17,135,184    6.7gb
events_2025_12_05           cold                   17,895,255    6.9gb
events_2025_12_06           cold                   12,078,779    4.5gb
events_2025_12_07           hot                         3,923    2.2mb
events_2025_12_08           hot                    10,339,585    4.1gb
events_2025_12_09           hot                    10,160,214    5.7gb
```

## Search Check

```text
hot count events_2025_12_09                 10,160,214    0.006s
cold count events_2025_12_05                17,895,255    0.007s
searchable snapshot count remote_2025_12_01 13,011,615    0.111s
mixed hot+cold+snapshot count               41,067,084    0.010s
```

## Important Findings

- `index.mapping.total_fields.limit=1000` was too low for real Dataskope Sysmon data. Dec08 hit `Limit of total fields [1000] has been exceeded`. The native/simple fix is template-level `index.mapping.total_fields.limit=5000`; no event content rewrite is needed.
- Retry after the template fix completed Dec08 and Dec09 with `failed=0`; no retry DLQ file was created.
- The pre-fix rejected events are preserved at `artifacts/rejected-events/fast-elasticdump-replay-errors.before-field-limit-20260521.ndjson`.
- Force-merge is the dominant cold-transition cost. Observed transient store peaks were materially larger than final store, for example Dec04 peaked around `14.1gb` and finished around `6.7gb`.
- Relocation after force-merge was less concerning in this run: 4.5-6.9GB shards moved hot -> cold in a few minutes.
- Searchable snapshot logical store is not expected to be much smaller than the force-merged source index. The real gain is moving old data ownership to the snapshot repository/object storage and bounding local search cache, not magical Lucene shrinkage.
- Dec03 has only `6,409,877` docs in the dump used by this run, while the earlier Elastic reference showed `15,131,190`. The `/events_2025_12_03.data.json` dump file is also much smaller than neighboring heavy days, so this looks like dump-source mismatch/incompleteness rather than a lifecycle failure.

## Team Lead Summary

ISM successfully managed the native flow for historical daily indexes:

```text
hot -> cold(read_only + force_merge + allocation) -> snapshot -> convert_index_to_remote -> delete source
```

This can replace the Curator archive/search-restore flow for searchable retention. It does not replace DR backup: MinIO/S3 snapshots still need their own durability, restore, and disaster-recovery procedure.
