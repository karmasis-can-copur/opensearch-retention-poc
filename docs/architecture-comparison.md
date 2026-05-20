# Architecture Comparison

## Current Elasticsearch Pattern

The existing archive pattern is effectively:

```text
hot Elasticsearch indexes -> snapshot/archive -> restore when old data must be searched
```

This keeps old data out of the hot cluster, but restored searches need an explicit restore flow and temporary full local disk for the restored period.

## OpenSearch Target Patterns

### Hot + Searchable Snapshot

```text
writer -> hot daily indexes -> ISM snapshot -> searchable snapshot -> delete source index after validation
```

Use this as the preferred simple target when the main goal is to maximize searchable retention while reducing always-on local disk. Snapshot repository storage remains required, but warm/searchable nodes only keep metadata/cache locally.

### Hot + Cold + Searchable Snapshot

```text
writer -> hot daily indexes -> cold read-only force-merged indexes -> searchable snapshot
```

Use this when Dataskope needs a lower-latency intermediate window or a controlled force-merge/relocation buffer. It adds local disk and data movement cost, so it should be justified by search behavior or operational needs.

## Current PoC Decision

The real-data run uses:

- 10 days hot.
- 10 days cold data tier.
- Remaining days searchable snapshot.
- MinIO S3-compatible snapshot repository on `/data`.

This shape measures both options in one run: the hot/cold local cost and the searchable snapshot repository/cache cost.

## Operational Notes

- Daily indexes are named `events_yyyy_MM_dd`.
- The writer sets `index.creation_date` from the daily index name.
- The writer does not know ISM policies.
- Backdated indexes are attached by `ism-policy-reconciler`.
- Native `convert_index_to_remote` should use a real remote repository. In this PoC, MinIO provides that S3-compatible repository.
- Snapshot/searchable archive is not the same as DR backup. Snapshot repository durability, replication, and retention are separate production requirements.

## What We Measure

- Raw dump bytes per day.
- Hot logical store and local disk.
- Cold logical store and local disk.
- Snapshot repository bytes in MinIO.
- Warm/searchable snapshot local cache.
- Cluster CPU/RAM/heap/disk.
- Search latency by stage.

The final sizing model should use measured real-data coefficients instead of synthetic sample estimates.
