# Real Dump Smoke - 2026-05-20

Environment:

- Server: `docker-os-cls` / `192.168.1.36`
- OpenSearch: `3.6.0`, 3 nodes: hot, cold, searchable snapshot/warm
- Snapshot repository: MinIO/S3 on `/data/minio`
- Policy: `events-hot-cold-snapshot-10-10`
- Smoke file: `/events_2025_12_07.data.json`

## Preflight

```text
summary.files=61
summary.missing=0
summary.hot_days=10
summary.cold_days=10
summary.raw_bytes=280348926756
summary.hot_files=10
summary.hot_raw_bytes=15825245907
summary.cold_files=10
summary.cold_raw_bytes=15715036225
summary.searchable_snapshot_files=41
summary.searchable_snapshot_raw_bytes=248808644624
estimate.hot_bytes=24054400000
estimate.cold_bytes=22472500000
estimate.snapshot_repo_bytes=355796000000
estimate.warm_cache_bytes=166702000000
estimate.local_cluster_with_headroom_bytes=277197570000
df.root=195868631040
df.data=249645506560
```

Conclusion: full 61-day ingest is storage-risky on the current VM. Use a subset for the next full lifecycle demo unless more disk is added.

## Smoke Ingest

Command:

```bash
./scripts/remote-run-dump-replay.sh /events_2025_12_07.data.json 5000 50000 events
```

Result:

```text
Replay completed. ProcessedTotal=3923, SentTotal=3923, RejectedTotal=0, ParseErrorTotal=0
```

Index creation date was set from the index name:

```text
events_2025_12_07 index.creation_date=1765065600000
```

## Lifecycle Result

ISM reconciler attached the policy to the backdated index:

```text
policy_id=events-hot-cold-snapshot-10-10
index_creation_date=1765065600000
state=hot -> cold -> snapshot_ready
```

Cold tier validation:

```text
events_2025_12_07 shards are on opensearch-cold
docs=3923
store=4158925 bytes
```

Snapshot action succeeded:

```text
snapshot=events_2025_12_07-2026.05.20-12:31:05.542
state=SUCCESS
```

Manual native restore API validated searchable snapshot:

```text
remote_events_2025_12_07
docs=3923
store=4158925 bytes
search size=0 took=10ms
MinIO repo bytes=4235026
```

## Important Finding

OpenSearch documentation says `convert_index_to_remote` converts an existing index to a searchable snapshot and deletes the original index after the restore request is accepted.

On OpenSearch `3.6.0`, the ISM action reached `convert_index_to_remote` but failed validation before creating `remote_events_2025_12_07`:

```text
Index [index=events_2025_12_07] already exists, cannot restore over existing index.
Validation Status is: FAILED. The action is convert_index_to_remote, state is snapshot_ready, step is attempt_restore.
```

The repository and snapshot are healthy because the same snapshot restored successfully as `remote_snapshot` through the native snapshot restore API. This isolates the problem to the ISM `convert_index_to_remote` action path, not MinIO/S3 or snapshot restore.

Current recommendation:

- Keep ISM for hot -> cold -> snapshot.
- Treat automatic ISM `convert_index_to_remote` as blocked until the OpenSearch 3.6 behavior is clarified or fixed.
- For the next demo, show searchable snapshot using the native restore API script, and explicitly call out that this is the remaining gap before removing every Curator-like operational step.
