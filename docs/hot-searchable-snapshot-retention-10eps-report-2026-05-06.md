# Hot + Searchable Snapshot 10+20 Retention PoC - 2026-05-06

## Scope

- Server: `docker-os-cls`, 24 core, 96 GB RAM, 489 GB usable SSD.
- Target: 10 days hot + 20 days searchable snapshot.
- Current cluster reset: OpenSearch 3.6.0, 1 hot node + 1 search node, local FS snapshot repository at `/mnt/snapshots`.
- MinIO/S3-compatible local repository was removed from the PoC by request.
- Chosen test rate: 10 EPS equivalent.
- Reason for 10 EPS: it creates the full 30-day lifecycle shape inside 500 GB with enough merge/snapshot/cache headroom.
- Data: 30 daily indexes, `events_2026_04_07` through `events_2026_05_06`.
- Documents: 864,000 docs/day, 25,920,000 docs total.
- Topology: 1 hot OpenSearch node + 1 search node, no cold node.
- Heap: hot 24 GB, search 8 GB.
- Template: Dataskope load-test template, 6 primary shards, 0 replicas.

## ISM Policy

Policy id: `events-hot-snapshot`.

Flow:

```text
hot -> snapshot_ready
```

`hot`:

- `index_priority=100`
- transition to `snapshot_ready` after `min_index_age=10d`
- writer sets `index.creation_date` from the daily index name at index creation time, so `min_index_age` uses the logical event day instead of wall-clock creation time

`snapshot_ready`:

- `read_only`
- `force_merge max_num_segments=1`
- `snapshot` to `dataskope_lifecycle_repo`
- `convert_index_to_remote` from `dataskope_lifecycle_repo` with `rename_pattern="remote_$1"`

Important behavior:

- OpenSearch ISM does not parse `events_yyyy_MM_dd` by itself. `min_index_age` is based on index creation time.
- OpenSearch 3.4+ lets us set `index.creation_date` during index creation. The writer now maps `events_2026_01_01` to `index.creation_date=1767225600000`.
- The writer no longer knows policy ids and no longer calls `_plugins/_ism/add`; lifecycle selection is no longer in writer code.
- The policy uses `ism_template` for `events_*`. Searchable snapshot indexes are named `remote_events_yyyy_MM_dd`, so they do not match the hot source pattern.
- Live validation on OpenSearch 3.6.0: producer created `events_2026_01_01`, settings showed `index.creation_date=1767225600000`, and after policy attach ISM moved it to `snapshot_ready` because it was already older than 10 days.
- Caveat: when a historical index is created with a creation date older than the ISM policy template `last_updated_time`, `ism_template` does not auto-attach. For bulk backfill of old dates, use a one-time operational ISM add/reconcile step after index creation, or create the policy/template before those logical creation dates are used.
- ISM successfully handled read-only, force-merge, and snapshot.
- OpenSearch 3.6.0 accepts `convert_index_to_remote` and accepts `rename_pattern`, but rejects `include_aliases` and `number_of_replicas` in this action.
- With local FS snapshot repository, runtime conversion failed validation: `Index [index=events_2026_04_02] already exists, cannot restore over existing index.` Snapshot succeeded; native convert did not complete.
- Official OpenSearch documentation says `convert_index_to_remote` requires a remote repository such as S3, Azure, or GCS. Since MinIO was removed from this PoC, a fully native no-extra-program searchable snapshot conversion still needs a real remote repository in the test/prod environment.

Correction applied after validation:

- Initial restore showed `*-frozen` indexes as ISM state `hot` because the snapshot restore carried/triggered ISM policy metadata.
- Those indexes were deleted and re-restored after removing policy auto-template and ignoring ISM policy settings during restore.
- Verified after fix: `managedFrozenCount=0`, `managedHotCount=10`; `events_2026_04_07-frozen` has `index.store.type=remote_snapshot`, `index.routing.allocation.require.temp=frozen`, and shards on `opensearch-search`.
- Name-date policy correction was replaced by OpenSearch 3.4+ `index.creation_date` override; the old `events-hot-snapshot-after-Nd` policies were removed from the live cluster.
- OpenSearch 3.6 FS-repo validation test: `events_2026_04_02` reached `snapshot_ready`, completed read-only, force-merge and snapshot, then `convert_index_to_remote` disabled the ISM job because FS restore could not replace the still-existing source index.

## Baseline: All 30 Days Hot

After loading all 30 daily indexes and refreshing:

| Metric | Value |
|---|---:|
| Hot indexes | 30 |
| Docs | 25,920,000 |
| Primary store | 41.7 GB |
| Docker local volumes | 45.0 GB |
| Root disk used | 55 GB |

Aggregate all-hot search:

| Set | Indexes | Hits | Avg ms | P95 ms |
|---|---:|---:|---:|---:|
| all hot | 30 | 25,920,000 | 75.80 | 79.63 |

## Final: 10 Hot + 20 Searchable Snapshot

After ISM snapshot and searchable snapshot restore:

| Set | Indexes | Docs | Logical store |
|---|---:|---:|---:|
| Hot | 10 | 8,640,000 | 13.9 GB |
| Searchable snapshot | 20 | 17,280,000 | 24.5 GB |
| Total searchable | 30 | 25,920,000 | 38.4 GB |

Actual Docker volume split:

| Volume | Usage |
|---|---:|
| `opensearch-hot-data` | 13 GB |
| `opensearch-search-data` | 7.7 GB |
| `opensearch-snapshots` | 23 GB |

Final root disk usage stayed around 57 GB. Event indexes were all green. Cluster health was yellow only because OpenSearch system indexes had unassigned replica shards in this 2-node PoC topology.

## Search Results

Aggregate final search:

| Set | Indexes | Hits | Avg ms | P95 ms | Max ms |
|---|---:|---:|---:|---:|---:|
| Hot all | 10 | 8,640,000 | 61.07 | 70.05 | 70.05 |
| Searchable snapshot all | 20 | 17,280,000 | 64.72 | 92.78 | 92.78 |
| All events | 30 | 25,920,000 | 81.40 | 81.90 | 81.90 |

Representative single-index search:

| Query group | Hot avg | Hot P95 | Searchable avg | Searchable P95 |
|---|---:|---:|---:|---:|
| match_all | 54.70 ms | 58.29 ms | 59.93 ms | 61.33 ms |
| time_range_all | 56.25 ms | 59.40 ms | 54.05 ms | 65.69 ms |
| eventid_range | 58.72 ms | 60.68 ms | 64.56 ms | 73.98 ms |
| eventsource_text_match | 68.39 ms | 96.42 ms | 74.33 ms | 119.15 ms |

## CPU and Memory Observations

Ingest:

- Producer loaded each 864k-doc day at roughly 9.5k-10k effective EPS while the scenario represented 10 EPS/day retention.
- Hot node CPU during ingest commonly ranged from about 100% to 335% container CPU.
- Hot node memory stayed around 26-27 GB container usage.
- Search node stayed mostly idle during ingest at about 8.8 GB container usage.

Final search/warm cache:

- Hot container: about 27.2 GB memory.
- Search container: about 9.3 GB memory after searchable snapshot queries warmed cache.
- During final aggregate search sampling, search node CPU briefly reached about 194% container CPU.

## Writer Guard

With `Producer__HotWindowDays=10`, a 2026-02-01 sample was tested:

- 100 generated events.
- Sent to OpenSearch: 0.
- Rejected dump lines: 100.
- `events_2026_02_01`: 404, not created.

This validates the rule: data outside hot window is not indexed but is not lost. Operationally, the DLQ/dump file needs an explicit ownership and rotation policy because container-written files may be root-owned on the host.

## Capacity Notes for This VM

Measured 10 EPS final footprint is about:

- Hot data: 13 GB.
- Snapshot repository: 23 GB.
- Search cache/data: 7.7 GB.

Linear planning from this run:

| EPS equivalent | Final footprint estimate | Transition risk if all 30 days are loaded before snapshot |
|---:|---:|---|
| 10 EPS | ~44 GB | Low |
| 25 EPS | ~110 GB | Low |
| 50 EPS | ~220 GB | Acceptable |
| 75 EPS | ~330 GB final | Risky because all-hot + repo during transition can approach disk limit |

For this 500 GB VM, 10 EPS is the right complete lifecycle PoC. A 50 EPS run is feasible as a stress follow-up if we load and snapshot carefully. 75 EPS should use day-by-day snapshot/delete orchestration or a larger snapshot repository disk.

## Artifacts

- `artifacts/resource-metrics/20260506-153941-retention-layout.json`
- `artifacts/resource-metrics/20260506-160752-retention-layout.json`
- `artifacts/resource-metrics/20260506-160808-hot-10eps-retention-events_2026_05_06.json`
- `artifacts/resource-metrics/20260506-160809-searchable-10eps-retention-events_2026_04_07-frozen.json`
- `opensearch/lifecycle/dataskope-ism-policy.hot-snapshot.poc.json`
- `scripts/prepare-retention-day-sample.ps1`
- `scripts/measure-retention-layout.ps1`
- `scripts/complete-searchable-snapshot.ps1`
