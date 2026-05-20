# Hot + Searchable Snapshot 5k EPS Report - 2026-05-06

## Test Topolojisi

- Server: `docker-os-cls`, 24 core, 96 GB RAM, 489 GB usable SSD.
- Cluster: 1 hot node + 1 search/searchable-snapshot node.
- Removed: cold tier.
- Hot heap: 24 GB.
- Search heap: 8 GB.
- Index template: Dataskope load-test template, 6 primary shard, 0 replica, 5s refresh.
- Policy: `events-hot-snapshot`.
- Flow: hot -> ISM read_only + force_merge + snapshot -> controller restores `remote_snapshot` -> validates search -> deletes original hot index.

## What Was Proven

- Writer sustained 5k EPS with varied test data.
- No event was rejected; DLQ/dump stayed empty.
- Hot index was created as `events_2026_05_06`.
- Snapshot candidate index was created as `events_2026_04_26`.
- ISM created snapshot successfully.
- Controller restored `events_2026_04_26-frozen` as searchable snapshot.
- Controller validated search and deleted original `events_2026_04_26`.
- Final state has no duplicate normal index for the frozen day.
- Event indexes are green. Cluster-level health is yellow only because OpenSearch system indexes have unassigned replica shards in this 2-node PoC topology.

## Measured Results

| Metric | Hot | Searchable Snapshot |
|---|---:|---:|
| Index | `events_2026_05_06` | `events_2026_04_26-frozen` |
| Docs | 250,000 | 250,000 |
| Logical store | 412 MB | 393 MB |
| Node | `opensearch-hot` | `opensearch-search` |
| Search avg | 56-58 ms | 56-69 ms |
| Search P95 worst | 80 ms | 81 ms |

Node/volume state after original source index delete:

| Area | Usage |
|---|---:|
| Hot data volume | 397 MB |
| Search cache/data volume | 280 MB |
| Snapshot repo | 376 MB |
| DLQ/dump | 4 KB |

During 5k EPS ingest, producer effective rate stayed around 5.0k EPS.

## 5k EPS Capacity Projection

5k EPS = 432,000,000 events/day.

Measured per-doc cost:

- Hot: ~1.65 KB/doc.
- Snapshot/searchable logical: ~1.57 KB/doc.

Projected primary data:

| Retention | Estimated disk |
|---|---:|
| 1 hot day | ~712 GB |
| 10 hot days | ~7.1 TB |
| 1 snapshot day | ~679 GB |
| 20 snapshot days | ~13.6 TB |

Recommended minimum with headroom:

- Hot usable SSD/NVMe: at least 11 TB for 10 days, including merge/headroom.
- Snapshot repository: at least 16 TB for 20 days, preferably object storage/NAS with backup/replication.
- Search cache disk: workload dependent; start with 2-4 TB for 20 snapshot days and tune by cache hit ratio.
- RAM: tested with 24 GB heap hot + 8 GB heap search. Minimum PoC fits on current 96 GB host. Production should use dedicated cluster-manager nodes.

## OpenSearch Searchable Snapshot vs Elasticsearch Free Snapshot

| Scenario | Disk | RAM/Nodes | Searchability | Curator replacement |
|---|---:|---|---|---|
| 10 hot + 20 searchable snapshot | Hot ~7.1 TB + repo ~13.6 TB + cache ~2-4 TB | Hot nodes + search nodes | Old 20 days searchable without full restore | ISM snapshot + small controller can replace Curator archive/restore flow |
| 10 hot + 20 plain snapshot | Hot ~7.1 TB + repo ~13.6 TB | No search nodes required | Old 20 days not searchable until restored | ISM/SM can replace scheduled snapshots, but search restore still requires an explicit restore workflow |

If Elasticsearch free has no searchable snapshots, the plain snapshot option uses less always-on RAM and cache disk, but it does not satisfy "old data remains searchable" unless a restore is performed. Restoring old data locally would temporarily consume roughly another full copy of the restored period on data nodes.

## Decision

For Dataskope, the simpler target architecture should be:

```text
OS writer with DLQ -> hot indexes -> ISM snapshot -> searchable snapshot controller -> delete original hot index
```

Cold tier should stay out of the default architecture. Curator can be removed for the archive/search path, but the replacement is not ISM alone: it is ISM snapshot actions plus a small Dataskope lifecycle controller that restores `remote_snapshot`, validates search, and deletes the original only after validation.

## Artifacts

- `artifacts/resource-metrics/20260506-114337-hot-5k-events_2026_05_06.json`
- `artifacts/resource-metrics/20260506-115238-searchable-snapshot-5k-events_2026_04_26-frozen.json`
- `opensearch/lifecycle/dataskope-ism-policy.hot-snapshot.poc.json`
- `scripts/complete-searchable-snapshot.ps1`
- `scripts/promote-hot-snapshot-by-date.ps1`
