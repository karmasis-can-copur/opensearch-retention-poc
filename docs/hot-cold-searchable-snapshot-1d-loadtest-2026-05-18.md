# Hot/Cold/Searchable Snapshot 1-Day PoC Load Test - 2026-05-18

## Scenario

- OpenSearch: 3.6.0 on docker-os-cls (`192.168.1.36`).
- Host capacity: 24 CPU, 96 GB RAM, 500 GB SSD.
- Cluster:
  - `opensearch-hot`: `cluster_manager,data,ingest`, `node.attr.temp=hot`, heap 24 GB.
  - `opensearch-cold`: `data`, `node.attr.temp=cold`, heap 16 GB.
  - `opensearch-search`: `warm`, `node.attr.temp=frozen`, heap 8 GB.
- Policy: `events-hot-cold-snapshot-1d`.
- Retention test target: 1 day hot, 1 day cold, 1 day searchable snapshot.
- Load: 3 daily indexes, 500,000 events each, producer target 5,000 EPS.

## Lifecycle Notes

- The writer creates daily indexes as `events_yyyy_MM_dd`.
- The writer sets `index.creation_date` from the index name, so `min_index_age` uses the logical event day.
- The writer does not know or attach ISM policies.
- OpenSearch `ism_template` did not auto-attach indexes whose `index.creation_date` was earlier than the policy `last_updated_time`.
- Direct index settings (`index.plugins.index_state_management.policy_id` and `index.opendistro.index_state_management.policy_id`) also did not make a backdated test index managed on OpenSearch 3.6.0.
- `ism-policy-reconciler` is therefore a lifecycle-layer sidecar. It periodically finds unmanaged `events_yyyy_MM_dd` indexes and calls `_plugins/_ism/add/{index}`.

For bulk backfill tests, pause the reconciler while writing historical indexes. Otherwise ISM can correctly mark the old index read-only while the load is still writing.

## Results

Cluster health was green after the final layout.

| Stage | Index | Docs | Logical store |
|---|---|---:|---:|
| hot | `events_2026_05_18` | 500,000 | 802,962,018 B |
| cold | `events_2026_05_17` | 500,000 | 754,908,313 B |
| searchable snapshot | `remote_events_2026_05_16` | 500,000 | 754,903,484 B |

Search latency (`size=0`, `match_all`, 1 warmup + 5 measured runs):

| Set | Hits | Avg ms | P95 ms | Max ms |
|---|---:|---:|---:|---:|
| hot | 500,000 | 53.63 | 54.67 | 54.67 |
| cold | 500,000 | 57.09 | 58.16 | 58.16 |
| searchable snapshot | 500,000 | 59.90 | 61.29 | 61.29 |
| all stages | 1,500,000 | 59.04 | 61.63 | 61.63 |

Docker volume usage after validation:

| Volume | Bytes | Meaning |
|---|---:|---|
| `opensearch-hot-data` | 804,415,074 | hot index local data |
| `opensearch-cold-data` | 755,975,048 | cold index local data |
| `opensearch-search-data` | 352,264,474 | searchable snapshot metadata/cache after search |
| `opensearch-snapshots` | 754,918,541 | local filesystem snapshot repository |

Docker stats after validation:

| Container | CPU | Memory |
|---|---:|---:|
| `opensearch-hot` | 1.72% | 25.91 GiB |
| `opensearch-cold` | 1.30% | 17.32 GiB |
| `opensearch-search` | 3.02% | 8.96 GiB |
| `opensearch-ism-policy-reconciler` | 0.00% | 556 KiB |

Artifacts:

- `artifacts/resource-metrics/20260518-180731-retention-layout.md`
- `artifacts/resource-metrics/20260518-180731-retention-layout.json`

## Important Findings

- Searchable snapshot requires a node with the `warm` role. A node with only the `search` role left `remote_snapshot` primary shards unassigned.
- Native `convert_index_to_remote` requires a remote repository such as S3, Azure, or GCS. With the local filesystem repository, the policy reached snapshot success but native conversion could not complete reliably.
- For this PoC, the searchable snapshot was restored manually from the successful ISM snapshot with `storage_type=remote_snapshot`, then the source index was deleted after count validation.
- The local filesystem snapshot repository is on the same host, so it counts as local disk in this PoC. In production, object storage should be off-cluster; only the warm-node cache/metadata should consume cluster disk.

## Capacity Estimate From This Sample

Measured bytes per event:

- Hot: about 1,606 B/event.
- Cold/snapshot repository: about 1,510 B/event.
- Warm searchable snapshot cache after a full `match_all`: about 705 B/event.

At sustained 5,000 EPS:

- 1 hot day is about 0.63 TiB.
- 10 hot days are about 6.31 TiB.
- 20 snapshot days are about 11.86 TiB in object storage or local repo.

With this event shape and mapping, the 500 GB test server is not enough for a real 10 hot + 20 searchable snapshot retention window at sustained 5,000 EPS. It is good for lifecycle validation and short 5k EPS bursts. Rough fit on 500 GB is around 134 EPS if the snapshot repository is local filesystem, or around 206 EPS if snapshots are external and the warm cache reaches the same ratio observed in this test.
