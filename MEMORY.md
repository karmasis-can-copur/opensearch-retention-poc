# OS Producer Project Memory

Last updated: 2026-05-21

## Goal

Dataskope icin OpenSearch lifecycle PoC yapiyoruz. OpenSearch tarafinda Elasticsearch ILM yerine ISM kullaniliyor. Ana hedef: eventleri gercek Dataskope semasina yakin sekilde yazmak, hot/cold/frozen-searchable yapisini dogrulamak, arama amacli arsiv ihtiyacinin lifecycle ile cozulup cozulmedigini gostermek, ama DR backup ile searchable archive ayrimini net tutmak.

## Current Architecture

Current Dataskope target architecture is Hot + Cold + Searchable Snapshot on OpenSearch 3.6 with MinIO/S3-compatible snapshot repository:

- OS writer validates event date against the configured hot window.
- Events inside hot window are written to daily `events_yyyy_MM_dd` indexes.
- Events outside hot window are not sent to OpenSearch, but are appended to the rejected-events dump/DLQ file.
- Writer creates daily indexes with `index.creation_date` set from the index name; ISM uses native `min_index_age`.
- Writer does not know the ISM policy id and does not call ISM APIs.
- ISM handles read-only, force-merge, allocation, snapshot, native `convert_index_to_remote`, and source delete.
- MinIO/S3 is the active snapshot repository for searchable snapshots.
- Keep the system native and simple; accept some disk cost rather than adding fragile lifecycle controllers unless the user approves.

Current active PoC files:

- `docker-compose.yml`
- `docker-compose.server.yml`
- `opensearch/lifecycle/dataskope-index-template.json`
- `opensearch/lifecycle/dataskope-index-template.loadtest.json`
- `opensearch/lifecycle/dataskope-index-template.window-1shard.json`
- `opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json`
- `opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-1d.poc.json`
- `opensearch/lifecycle/snapshot-repository.s3-minio.json`
- `scripts/poc-up.sh`
- `scripts/bootstrap-lifecycle.sh`
- `scripts/poc-status.sh`
- `scripts/preflight-real-dump.sh`
- `scripts/make-window-policy.py`
- `scripts/run-real-retention-managed-ingest.sh`
- `scripts/summarize-retention-metrics.sh`
- `docs/team-lead-demo.md`
- `docs/lifecycle-management.md`
- `docs/real-dump-window-3-3-3-2026-05-20.md`

Important lifecycle correction:

- OpenSearch 3.4+ allows `index.creation_date` to be set during index creation. Current writer behavior: for daily indexes like `events_2026_01_01`, it creates the index with `index.creation_date=1767225600000` (UTC midnight for the date in the name).
- Writer no longer knows about ISM policy ids and no longer calls the ISM add API. It only derives the OpenSearch index creation date from the index name during index creation.
- Current policy model uses `events-hot-cold-snapshot-10-10` for normal PoC and generated `events-window-*` policies for historical windows.
- `convert_index_to_remote` renames searchable snapshot indexes to `remote_$1` so they do not match the hot source pattern.
- Live validation: writer created `events_2026_01_01` with `index.creation_date=1767225600000` and 3 docs. After `events-hot-snapshot` was attached, ISM transitioned it to `snapshot_ready`, proving `min_index_age` uses the overridden creation date.
- Caveat found live: if `index.creation_date` is older than the ISM policy template `last_updated_time`, OpenSearch's `ism_template` does not auto-attach the policy because the index appears older than the template. For backfilled historical indexes, a one-time operational ISM add/reconcile step is still needed unless the policy template predates the overridden creation date.
- OpenSearch 3.6.0 was accepted as target and is now used in compose. Current PoC uses MinIO because the real-data plan requires an S3-compatible searchable snapshot repository on `/data`.
- OpenSearch 3.6.0 accepts ISM `convert_index_to_remote` and `rename_pattern`, but rejects `include_aliases` and `number_of_replicas` in `ConvertIndexToRemoteAction`.
- Live FS-repo test: `events_2026_04_02` reached read-only, force-merge, and snapshot successfully; `convert_index_to_remote` then failed validation with `Index [index=events_2026_04_02] already exists, cannot restore over existing index` and disabled the ISM job. Conclusion: for fully native no-extra-program searchable snapshot conversion, use a real remote repository (S3/Azure/GCS), not local FS.

## Hot/Cold/Search Architecture

- Docker Compose services:
  - `opensearch-hot`: cluster manager + data + ingest, `node.attr.temp=hot`, port 9200.
  - `opensearch-cold`: data, `node.attr.temp=cold`.
  - `opensearch-search`: `node.roles=search`, `node.attr.temp=frozen`, searchable snapshot cache.
  - `opensearch-dashboards`: port 5601.
  - `opensearch-snapshot-init`: shared snapshot volume permissions.
  - `event-producer`: .NET 9 producer.
- Snapshot repo: `dataskope_lifecycle_repo`, S3 endpoint `minio:9000`, bucket `dataskope-opensearch-snapshots`.
- Security is disabled for local PoC.

## Index Model

- Default prefix: `events`.
- Concrete daily index format: `events_yyyy_MM_dd`.
- Producer routes by event `TimeCreated`; fallback is runtime timestamp.
- `Producer:PreserveDateFields=true` keeps sample date fields unchanged.
- Producer now has a hot-window ingest guard: `Producer:DropEventsOutsideHotWindow=true`, `Producer:HotWindowDays=30` by default.
- Events outside the hot window, including older-than-window and future-dated events, are not published to OpenSearch. They must be appended to `Producer:RejectedEventsDumpFilePath` as NDJSON. If the dump path is missing while the guard is enabled and not in dry-run mode, producer startup fails to avoid silent data loss.
- OpenSearch ISM `min_index_age` uses index creation time, not date encoded in index name.
- Backfill/old event-date indexes must be created with `index.creation_date` set from the daily index name; do not reintroduce a date-promote script unless explicitly approved.

## Mapping Template

User added `elasticsearch-template-for-dataskope.txt`, a legacy Elasticsearch `_template` with `_default_`.

Converted OpenSearch 2.x template is `opensearch/lifecycle/dataskope-index-template.json`:

- Pattern: `events_*`.
- 3 primary shards, 0 replica for local PoC.
- `index.routing.allocation.require.temp=hot`.
- Strings map to `text` with `raw` keyword subfield, `ignore_above=250`, `norms=false`.
- Real Sysmon dump data exceeded OpenSearch's default `index.mapping.total_fields.limit=1000`; current templates set `index.mapping.total_fields.limit=5000` to preserve event content without writer-side schema changes.
- `date_detection=false`, `numeric_detection=false`.
- `TimeCreated` and `TimeInserted`: `date`.
- `EventID`, `Level`, `Severity`, `DataLabel`: `float`.
- `_all` is omitted because OpenSearch 2.x does not support the old setting.

## Lifecycle Policy

Policy id: `events-hot-cold-snapshot-10-10`.

File: `opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json`.

State flow:

- `hot`: priority 100, transition to cold after `min_index_age=10d`.
- `cold`: read_only, optional force_merge max_num_segments=1, allocation require `temp=cold`, priority 50.
- `snapshot_ready`: read_only, optional force_merge, allocation require `temp=frozen`, snapshot to `dataskope_lifecycle_repo`, convert to `remote_$1`, delete source index after cold/index age reaches `20d`.

`bootstrap-lifecycle.sh` sets ISM job interval to 1 minute for PoC observation.

## Important Scripts

- `scripts/poc-up.sh`: starts the Docker PoC stack.
- `scripts/bootstrap-lifecycle.sh`: waits for cluster, registers MinIO repo, upserts ISM policy, puts index template.
- `scripts/poc-status.sh`: shows health, nodes, index/stage summary.
- `scripts/preflight-real-dump.sh`: checks dump files and storage before ingest.
- `scripts/make-window-policy.py`: generates a native min_index_age policy for a historical date window and supports `--force-merge none|cold|snapshot|both`.
- `scripts/run-real-retention-managed-ingest.sh`: ingests day by day, waits for expected stage, records CSV metrics.
- `scripts/remote-run-dump-replay.sh`: runs producer against one elasticdump file.
- `scripts/fast-elasticdump-replay.py`: bulk replay path used by managed ingest.
- `scripts/summarize-retention-metrics.sh`: summarizes the managed ingest CSV.

## Verified Locally

- `dotnet test OpenSearchEventProducer.Tests\OpenSearchEventProducer.Tests.csproj --no-restore -v minimal`: passed 3 tests.
- Docker PoC wrote 6 sample events to `events_2026_04_23`.
- Historical local validation promoted `events_2026_04_23` to cold with an older PowerShell helper. Those helpers were removed in the 2026-05-21 cleanup.
- Cold state: 3 shards on `opensearch-cold`, `_search` returned 6 docs.
- Searchable snapshot: `events_2026_04_23-frozen` restored as `remote_snapshot`, 3 shards on `opensearch-search`, `_search` returned 6 docs.
- Bootstrap after Elasticsearch-template conversion succeeded and updated `events-template`.
- Resource measurement scripts were smoke-tested:
  - Cold: `artifacts/resource-metrics/20260505-152256-cold-events_2026_04_23.json`
  - Frozen: `artifacts/resource-metrics/20260505-152256-frozen-events_2026_04_23-frozen.json`
  - Comparison: `artifacts/resource-metrics/comparison-20260505-152303.md`
- The small 6-doc measurement is only a script validation. It is too small for capacity decisions and was created before the converted Elasticsearch template, so future capacity tests must recreate indexes after bootstrap.

## Verified on docker-os-cls

Test server:

- Host/IP: `docker-os-cls` / `192.168.1.36`.
- Ubuntu 24.04.4 LTS, Docker Engine 29.4.2, Compose v5.1.3.
- 24 core, 96 GB RAM, root LV expanded to 489 GB.
- OpenSearch server profile started with 24g hot heap, 16g cold heap, 8g search heap.
- `vm.max_map_count=1048576`.

Lifecycle/bootstrap:

- Bootstrap against `http://192.168.1.36:9200` succeeded with `dataskope-index-template.loadtest.json`.
- Cluster green with 3 nodes: `opensearch-hot`, `opensearch-cold`, `opensearch-search`.
- ISM job interval is 1 minute and jitter is 0 for PoC observation.

Data loaded on 2026-05-05:

- `events_2026_05_05`: hot day, 1,020,000 docs.
- `events_2026_05_04`: cold day, 1,020,000 docs.
- `events_2026_05_03`: cold -> snapshot_ready -> frozen source day, 1,020,000 docs.
- Single producer container with target 30k EPS achieved about 11k-11.4k EPS effective throughput. This is the next tuning target before full performance testing.

Measured stage results:

- Hot stable: `events_2026_05_05`, 1,020,000 docs, 1.72 GB logical primary store, shards on `opensearch-hot`, search avg roughly 54-61 ms.
- Hot immediate post-ingest was 2.16 GB logical primary store before background merges finished; keep merge headroom in capacity plans.
- Cold: `events_2026_05_03`, 1,020,000 docs, 1.52 GB logical primary store after force-merge, shards on `opensearch-cold`, search avg roughly 58-64 ms.
- Frozen: `events_2026_05_03-frozen`, 1,020,000 docs, `index.store.type=remote_snapshot`, shards on `opensearch-search`, search avg roughly 60-63 ms.
- Artifacts:
  - `artifacts/resource-metrics/20260505-173100-hot-stable-events_2026_05_05.json`
  - `artifacts/resource-metrics/20260505-170922-hot-events_2026_05_05.json`
  - `artifacts/resource-metrics/20260505-172220-cold-events_2026_05_03.json`
  - `artifacts/resource-metrics/20260505-172638-frozen-events_2026_05_03-frozen.json`
  - `artifacts/resource-metrics/20260505-hot-cold-frozen-comparison.md`

Observed lifecycle timings/behavior:

- This was an early run before `index.creation_date` override was adopted.
- Cold action order observed: `read_only`, `force_merge`, `allocation`, `index_priority`, then transition evaluation.
- Force-merge was the main wait. Relocation of a 1.45 GB force-merged index with 6 shards took about 13 seconds once allocation started.
- During relocation, observed container stats were roughly 41% CPU on hot and 21% CPU on cold, with cold block write around 5.7 GB.
- ISM snapshot action created `events_2026_05_03-2026.05.05-14:24:42.800` successfully in `dataskope_lifecycle_repo`.
- Searchable snapshot restore created `events_2026_05_03-frozen` as `remote_snapshot` on `opensearch-search` and search passed.

## Verified Hot + Searchable Snapshot on docker-os-cls

Date: 2026-05-06.

Topology:

- Cluster rebuilt with 2 OpenSearch nodes: `opensearch-hot` and `opensearch-search`.
- Cold node was removed from the active PoC topology.
- Hot heap: 24 GB. Search heap: 8 GB.
- Policy id: `events-hot-snapshot`.
- Index template: `dataskope-index-template.loadtest.json`, 6 primary shards, 0 replica, 5s refresh.

Data/test:

- Generated varied test data from Dataskope sample events with updated nested `_source.TimeCreated` / `TimeInserted`.
- Writer bug fixed: timestamp detection now recursively reads nested `_source.TimeCreated`, so Elasticsearch-export-style sample wrappers route to the correct daily index.
- 5k EPS producer run wrote 250,000 docs to `events_2026_05_06`.
- 5k EPS producer run wrote 250,000 docs to `events_2026_04_26`.
- No events were rejected; rejected-events dump stayed effectively empty.

Lifecycle/search validation:

- `events_2026_04_26` was promoted to `snapshot_ready`.
- ISM completed `read_only`, `force_merge`, and snapshot action.
- Snapshot created successfully as `events_2026_04_26-2026.05.06-08:50:27.948`.
- An older manual restore helper restored `events_2026_04_26-frozen` as `index.store.type=remote_snapshot`, validated search with 250,000 hits, then deleted original `events_2026_04_26`.
- Final event indexes: `events_2026_05_06` and `events_2026_04_26-frozen`, both green.
- Cluster-level health was yellow only because OpenSearch system indexes had unassigned replica shards in the 2-node/0-replica PoC shape; event indexes were green.

Measured results:

- Hot `events_2026_05_06`: 250,000 docs, 393 MB `_cat/indices`, 412 MB store stats, search avg roughly 56-58 ms, worst P95 80 ms.
- Searchable snapshot `events_2026_04_26-frozen`: 250,000 docs, 374 MB `_cat/indices`, 393 MB store stats, search avg roughly 56-69 ms, worst P95 81 ms.
- Final Docker volume usage after deleting the original snapshot source index: hot data 397 MB, search cache/data 280 MB, snapshot repo 376 MB, rejected-events dump 4 KB.
- Metric artifacts:
  - `artifacts/resource-metrics/20260506-114337-hot-5k-events_2026_05_06.json`
  - `artifacts/resource-metrics/20260506-115238-searchable-snapshot-5k-events_2026_04_26-frozen.json`

5k EPS projection from measured data:

- 5k EPS = 432,000,000 events/day.
- Hot measured cost is about 1.65 KB/doc, so 1 hot day is roughly 712 GB primary store and 10 hot days roughly 7.1 TB.
- Searchable snapshot measured logical cost is about 1.57 KB/doc, so 1 snapshot day is roughly 679 GB and 20 snapshot days roughly 13.6 TB in the repository.
- Minimum planning numbers with headroom: at least 11 TB usable hot SSD/NVMe, at least 16 TB snapshot repository, and 2-4 TB search cache disk to start.
- Current 500 GB server proves the lifecycle and extrapolates capacity, but cannot physically hold 10 hot + 20 snapshot days at 5k EPS.

## Verified 10+20 Retention PoC on docker-os-cls

Date: 2026-05-06.

Purpose:

- Build the full 10 days hot + 20 days searchable snapshot shape on the 500 GB test VM.
- Use an EPS equivalent that fits the VM while still creating all real daily indexes and lifecycle states.

Chosen rate:

- 10 EPS equivalent.
- 864,000 docs/day.
- 30 daily indexes from `events_2026_04_07` through `events_2026_05_06`.
- 25,920,000 total docs.
- Loader ran at about 9.5k-10k effective EPS to avoid waiting real-time days.

Baseline before lifecycle:

- 30 hot indexes, all green.
- 25,920,000 docs.
- 41.7 GB primary store.
- Docker local volumes about 45.0 GB.

ISM behavior:

- `events_2026_04_07` through `events_2026_04_26` were promoted to `snapshot_ready` by an older helper before the current native window-policy approach.
- Promotion was needed because this is a backfill-style PoC; OpenSearch ISM `min_index_age` uses index creation time.
- ISM completed read-only, force-merge, and snapshot for 20 indexes.
- 20 SUCCESS snapshots completed in about 26 minutes on the local snapshot repo.

Final state:

- 10 hot indexes: `events_2026_04_27` through `events_2026_05_06`.
- 20 searchable snapshot indexes: `events_2026_04_07-frozen` through `events_2026_04_26-frozen`.
- All event indexes green.
- Cluster health yellow only because OpenSearch system indexes had unassigned replicas in the 2-node/0-replica PoC topology.
- Total event count stayed 25,920,000 after deleting source hot indexes for searchable snapshot days.

ISM/frozen correction:

- Initial frozen restore had a design bug: `events_2026_04_07-frozen` and peers were physically `remote_snapshot` on `opensearch-search`, but ISM explain showed policy `events-hot-snapshot`, state `hot`, failed `index_priority`, and `enabled=false`.
- Removing policy with `_plugins/_ism/remove` failed with HTTP 500 because remote snapshot indexes are read-only.
- Fix applied live in the older run: update policy to remove `ism_template`; delete the 20 frozen indexes; re-restore them from snapshots while ignoring ISM policy settings.
- Verified after 75 seconds: `managedFrozenCount=0`, `managedHotCount=10`.
- Sample settings after fix: `events_2026_04_07-frozen` has `index.store.type=remote_snapshot`, `index.routing.allocation.require.temp=frozen`, no ISM policy id, and shards on `opensearch-search`.
- Existing hot indexes were reattached to name-date policies with remove + add because `change_policy` did not immediately update explain state: `events_2026_04_27 -> after-1d`, `events_2026_05_03 -> after-7d`, `events_2026_05_06 -> after-10d`.

Final measured resources:

- Hot set: 10 indexes, 8,640,000 docs, 13.9 GB logical store.
- Searchable snapshot set: 20 indexes, 17,280,000 docs, 24.5 GB logical store.
- Docker volumes: hot data 13 GB, search data/cache 7.7 GB, snapshot repo 23 GB.
- Root disk used about 57 GB.
- Aggregate search: hot_all avg 61.07 ms / P95 70.05 ms; searchable_snapshot_all avg 64.72 ms / P95 92.78 ms; all_events avg 81.40 ms / P95 81.90 ms.
- Representative hot index `events_2026_05_06`: 864,000 docs, 1.39 GB, query avg about 55-68 ms.
- Representative searchable index `events_2026_04_07-frozen`: 864,000 docs, 1.23 GB, query avg about 54-74 ms.

Writer guard validation:

- With `Producer__HotWindowDays=10`, 100 events dated 2026-02-01 were rejected and written to the rejected-events dump.
- `events_2026_02_01` was not created.
- The rejected-events dump may be container/root-owned on the host, so production needs an explicit ownership and rotation policy.

Artifacts:

- `artifacts/resource-metrics/20260506-153941-retention-layout.json`
- `artifacts/resource-metrics/20260506-160752-retention-layout.json`
- `artifacts/resource-metrics/20260506-160808-hot-10eps-retention-events_2026_05_06.json`
- `artifacts/resource-metrics/20260506-160809-searchable-10eps-retention-events_2026_04_07-frozen.json`

Disk/resource distinction:

- `_cat/indices` shows frozen logical store around 1.52 GB, same as cold.
- Actual Docker volumes after restore showed: hot data 1.7 GB, cold data 2.9 GB for two cold indexes, search/frozen data 299 MB, snapshot repo 1.5 GB.
- For frozen, the repository is the primary data source; search node holds metadata/cache, so logical store and local disk must be reported separately.

## Resource Measurement Plan

OpenSearch does not provide exact per-index CPU/RAM isolation. Use:

- Index disk from `_cat/indices` and `/<index>/_stats/store`.
- Shard placement from `_cat/shards`.
- Index segment/search/cache stats from `/<index>/_stats` and `/<index>/_segments?verbose=true`.
- Node CPU/RAM/disk from `_cat/nodes` and `/_nodes/stats`.
- Local container CPU/RAM from `docker stats --no-stream`.

Current measurement path is `scripts/run-real-retention-managed-ingest.sh` plus `scripts/summarize-retention-metrics.sh`. The older PowerShell per-stage scripts were removed in the 2026-05-21 cleanup to keep the project simple.

## 30k EPS Notes

30k EPS for 86,400 seconds is 2,592,000,000 events/day. Current sample average line size is about 1,056 bytes, so raw JSON alone is about 2.55 TiB/day before index overhead and replicas.

The 1.02M-doc server run implies a very rough line-rate projection:

- 1 full 30k EPS day hot stable with this mapping is around 4.4 TB primary store.
- 1 full 30k EPS day hot immediate/merge-headroom is around 5.5 TB primary store.
- Force-merged cold is around 3.9 TB primary store.
- Frozen snapshot repo is around 3.8 TB.
- The current 500 GB test server is enough for lifecycle validation and short 30k bursts, not a full 1 hot day + 1 cold day + 1 frozen day retention run at 30k EPS.

For production-like testing, avoid one giant daily index. Keep calendar-day semantics but shard/rollover by size:

- `events_2026_05_05_000001`
- `events_2026_05_05_000002`

Initial target primary shard size to test: 30-80 GB. Need empirical resource test because current Dataskope mapping uses `text + raw` for every string, which increases disk and segment cost compared with keyword-only mapping.

Minimum large-test discussion point:

- 1 day hot, 1 day cold, 1 day frozen is reasonable.
- Need dedicated cluster-manager nodes for real scale.
- Hot nodes need SSD/NVMe and merge headroom.
- Cold nodes need enough disk and relocation bandwidth.
- Frozen/search nodes need cache disk and should be dedicated for predictable latency.

## Known Pitfalls

- Current PoC target architecture is Hot + Cold + Searchable Snapshot, with MinIO/S3 as the snapshot repository.
- Keep the ingest hot-window guard enabled in normal operation. Otherwise a 3-month-old event can create an old-date `events_yyyy_MM_dd` index and reintroduce backfill lifecycle complexity.
- Searchable snapshot restore can inherit cold allocation; current ISM policy sets allocation to `temp=frozen` before convert.
- Frozen/searchable snapshot requires snapshot repository; it can replace search archive flows, but not DR backup requirements.
- Force-merge is expensive and should not run on hot ingest nodes during peak load at 30k EPS.
- ISM policy updates do not instantly rewrite all managed index state; inspect with `_plugins/_ism/explain/<index>`.

## 2026-05-18 1d Hot/Cold/Searchable Snapshot Load Test

Cluster on `docker-os-cls` (`192.168.1.36`) was rebuilt with OpenSearch 3.6.0:

- `opensearch-hot`: `cluster_manager,data,ingest`, `node.attr.temp=hot`, 24 GB heap.
- `opensearch-cold`: `data`, `node.attr.temp=cold`, 16 GB heap.
- `opensearch-search`: `warm`, `node.attr.temp=frozen`, 8 GB heap. Searchable snapshot primary shards require the `warm` role; a `search`-only node left `remote_snapshot` shards unassigned.
- `ism-policy-reconciler`: tiny `curlimages/curl` sidecar that periodically attaches policy to unmanaged daily indexes.

Important lifecycle result:

- Writer creates `events_yyyy_MM_dd` and sets `index.creation_date` from the index name, but still has no ISM policy awareness.
- OpenSearch `ism_template` did not auto-attach a backdated index when `index.creation_date` was older than the policy `last_updated_time`.
- Direct index settings `index.plugins.index_state_management.policy_id` and `index.opendistro.index_state_management.policy_id` were tested on OpenSearch 3.6.0 and also did not make a backdated test index managed.
- Therefore automatic attach for backdated daily indexes is handled by the lifecycle-layer reconciler, not by the writer.
- For bulk backfill tests, pause the reconciler while loading historical indexes. Otherwise ISM can correctly make old indexes read-only while the producer is still writing.

Load test:

- Policy: `events-hot-cold-snapshot-1d`.
- Dates: `events_2026_05_18` hot, `events_2026_05_17` cold, `remote_events_2026_05_16` searchable snapshot.
- Producer target: 5,000 EPS.
- Loaded 500,000 events per day, 1,500,000 total, 0 rejected.
- `events_2026_05_16` snapshot completed in 18 seconds.
- Native `convert_index_to_remote` reached validation trouble in the old filesystem-repository run. Current PoC uses MinIO/S3 and disables action validation in bootstrap based on the 2026-05-20 OpenSearch 3.6 observation.

Final measured layout:

- Hot `events_2026_05_18`: 500,000 docs, 802,962,018 B logical store.
- Cold `events_2026_05_17`: 500,000 docs, 754,908,313 B logical store.
- Searchable snapshot `remote_events_2026_05_16`: 500,000 docs, 754,903,484 B logical store.
- Docker volume usage: hot 804,415,074 B, cold 755,975,048 B, warm/search cache 352,264,474 B, local snapshot repo 754,918,541 B.
- Search latency for `size=0 match_all`: hot avg 53.63 ms, cold avg 57.09 ms, searchable snapshot avg 59.90 ms, all three avg 59.04 ms.
- Docker stats after validation: hot 1.72% CPU / 25.91 GiB, cold 1.30% CPU / 17.32 GiB, warm 3.02% CPU / 8.96 GiB, reconciler 556 KiB.

Capacity projection from this sample:

- Hot is about 1,606 B/event.
- Snapshot repo is about 1,510 B/event.
- Warm searchable snapshot cache after a full scan is about 705 B/event.
- Sustained 5,000 EPS is about 0.63 TiB per hot day, 6.31 TiB for 10 hot days, and 11.86 TiB for 20 snapshot days in object storage/local repo.
- The 500 GB test server is not enough for a real 10 hot + 20 searchable snapshot retention window at sustained 5,000 EPS with this mapping. Rough fit is around 134 EPS if the snapshot repository is local filesystem, or around 206 EPS if snapshots are external and warm cache grows like this test.

Artifacts:

- `artifacts/resource-metrics/20260518-180731-retention-layout.md`
- `artifacts/resource-metrics/20260518-180731-retention-layout.json`
- `opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-1d.poc.json`
- `scripts/reconcile-ism-policy.sh`

## 2026-05-20 Real Dump + MinIO PoC Implementation Notes

Dump completion note:

- The real elasticdump files under `/` are treated as complete based on the operator signal; `.done` marker files are intentionally not part of the PoC scripts.
- `scripts/preflight-real-dump.sh` validates expected dump files and storage. Managed ingest validates each day before replay.

Target repo is `https://github.com/karmasis-can-copur/opensearch-retention-poc` and should be pushed as a clean private PoC package.

New implementation direction:

- Runtime moved to `.NET 10`.
- Retention dashboard added on port `9205` as `OpenSearchRetentionDashboard`.
- Dashboard is read-only/destructive-free: cluster summary, retention stage layout, safe search templates, and EPS calculator.
- Real dump replay mode added to the producer with `Producer__ReplayInputFile=true`. This streams elasticdump NDJSON line-by-line, extracts `_source`, preserves event content, resolves `TimeCreated`, and avoids loading 11 GB daily dump files into memory.
- Real dump scripts added:
  - `scripts/preflight-real-dump.sh`
  - `scripts/remote-run-dump-replay.sh`
  - `scripts/run-real-retention-managed-ingest.sh`
- Compose now includes MinIO using `/data/minio` by default and `minio-init` creates bucket `dataskope-opensearch-snapshots`.
- OpenSearch nodes now build from `docker/opensearch-s3/Dockerfile`, which installs `repository-s3` and injects MinIO credentials into the OpenSearch keystore at startup.
- S3 repository definition is `opensearch/lifecycle/snapshot-repository.s3-minio.json`.
- Real retention policy is `opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json`: 10d hot, 10d cold, then snapshot/searchable snapshot.
- `bootstrap-lifecycle.sh` defaults to the 10+10 policy and the S3/MinIO repository file.

Remote smoke validation on docker-os-cls:

- Real dump smoke used `/events_2025_12_07.data.json`, 4,833,828 raw bytes.
- Producer replay streamed 3,923 events, sent 3,923, rejected 0, parse errors 0.
- Writer created `events_2025_12_07` with `index.creation_date=1765065600000`.
- ISM reconciler attached `events-hot-cold-snapshot-10-10`; the index moved hot -> cold -> snapshot_ready and shards relocated to `opensearch-cold`.
- Snapshot `events_2025_12_07-2026.05.20-12:31:05.542` completed successfully in MinIO/S3.
- Manual native snapshot restore created `remote_events_2025_12_07` with `index.store.type=remote_snapshot`; search returned 3,923 docs.
- Measured smoke sizes: cold source primary store 4,158,925 B, remote primary store 4,158,925 B, MinIO repo 4,235,026 B.
- Important correction: ISM `convert_index_to_remote` on OpenSearch/index-management 3.6.0.0 failed only because `plugins.index_state_management.action_validation.enabled=true` runs `ValidateConvertIndexToRemote`, whose bytecode checks `indexExists(indexName)` against the source managed index before restore. Bootstrap now sets action validation to false so the native restore step can run.
- Root disk usage around 287 GB after cluster cleanup is mostly raw dump files, not OpenSearch: `/events_*.data.json` is 280,348,926,756 bytes and `/var/lib/docker` was about 11 GB after cleanup/rebuild.
- Faster replay path added: `scripts/fast-elasticdump-replay.py` streams elasticdump hit lines to OpenSearch `_bulk`, pre-creates `events_yyyy_MM_dd` with `index.creation_date` from the index name, and avoids the throttled .NET producer path. `run-real-retention-managed-ingest.sh` defaults to `INGEST_MODE=bulk`.
- Window policy generator added: `scripts/make-window-policy.py`. It keeps real index dates intact and calculates `min_index_age` thresholds for a selected historical window, for example 2025-12-23..2025-12-31 as 3 searchable snapshot + 3 cold + 3 hot.
- OpenSearch/index-management 3.6.0.0 `convert_index_to_remote` accepts only `repository`, `snapshot`, and `rename_pattern`; it rejects `ignore_index_settings` and `number_of_replicas`.
- Native policy workaround: `snapshot_ready` sets allocation to `temp=frozen` before snapshot/convert so restored remote snapshot shards allocate to `opensearch-search` instead of inheriting cold/hot placement. Add explicit `delete` after `convert_index_to_remote` because the 3.6.0 run completed restore but did not delete the source index automatically.
- 2026-05-20 real December 3+3+3 run completed: 2025-12-23..25 searchable snapshot, 2025-12-26..28 cold, 2025-12-29..31 hot. Total 9 days, 8,139,975 docs, 13.02 GiB raw, 6.06 GiB all-hot logical store, 5.91 GiB final local logical store, 2.35 GiB MinIO repo. Evidence doc: `docs/real-dump-window-3-3-3-2026-05-20.md`.

## 2026-05-21 Real Dump Window Run

- Completed `2025-12-01..2025-12-09` with generated `events-window-3-3-3` policy and 1 primary shard.
- Layout: `remote_events_2025_12_01..03` searchable snapshot, `events_2025_12_04..06` cold, `events_2025_12_07..09` hot.
- Summary: 9 days, 99,862,203 docs, 180.50 GiB raw, 46.76 GiB all-hot logical store, 40.51 GiB final logical store, 12.64 GiB MinIO snapshot repository.
- Search validation: hot count 0.006s, cold count 0.007s, searchable snapshot count 0.111s, mixed hot+cold+snapshot count succeeded.
- Dec08 initially failed with `Limit of total fields [1000] has been exceeded`; fixed natively by setting `index.mapping.total_fields.limit=5000` in all active templates and retrying Dec08-Dec09. Retry finished with `failed=0` and no retry DLQ file.
- Pre-fix rejected events are preserved in `artifacts/rejected-events/fast-elasticdump-replay-errors.before-field-limit-20260521.ndjson`.
- Force-merge was the dominant cold-stage cost; observed transient store peaked around 10.2-14.1GB for final 4.5-6.9GB cold shards. Relocation of those shards took a few minutes after allocation started.
- Evidence doc: `docs/real-dump-window-3-3-3-2026-05-21.md`.

## 2026-05-22 Force-Merge Decision

- Force-merge is now treated as product-configurable, not mandatory.
- `scripts/make-window-policy.py` supports `--force-merge none|cold|snapshot|both`.
- Real-data comparison showed little disk gain: Elastic 7.16 hot and OpenSearch hot/cold force-merged sizes are in the same band for Dec04-Dec09.
- Recommended default is `force_merge=none`; enable per stage only if segment count, query latency, or snapshot/restore metadata overhead proves it is useful.
- Estimated no-force retention transition cost from the measured ISM history: cold about 2-5 minutes per index, searchable snapshot about 5-8 minutes per index, instead of 16-19 minutes with force-merge.
- Final report: `docs/final-retention-report-2026-05-22.md`.

Important user constraint:

- Do not re-check `/events_*` dump readiness until the user says the elasticdump run is done.
- The dump files are on `.36` under `/events_YYYY_MM_DD.data.json`; raw dump files must not be committed to Git.
- MinIO must use the separate `/data` disk (`/dev/sdb1`, about 233 GB free when discussed).

Validation completed locally:

- `dotnet restore OpenSearchEventProducer.sln` succeeded with elevated access to user NuGet config.
- `dotnet test OpenSearchEventProducer.sln --no-restore -v minimal` passed 16 tests on `net10.0`.
- `dotnet publish OpenSearchRetentionDashboard/OpenSearchRetentionDashboard.csproj -c Release --no-restore` succeeded.
- `docker compose -f docker-compose.yml -f docker-compose.server.yml config` succeeded, with only a local Docker config access warning.
- All JSON files in `opensearch/lifecycle` parsed successfully.
