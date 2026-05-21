# Cluster Calculator

The retention dashboard includes a first-pass EPS calculator. It estimates storage and node counts from measured bytes-per-event coefficients.

## Inputs

- EPS.
- Hot days.
- Cold days.
- Searchable snapshot days.
- Replica factor.
- Disk headroom factor.
- Bytes per event for hot, cold, snapshot repository, warm cache, and raw dump.

## Defaults

The current defaults come from earlier Dataskope-shaped PoC measurements:

| Coefficient | Default |
|---|---:|
| Raw dump | 1056 B/event |
| Hot index | 1606 B/event |
| Cold index | 1510 B/event |
| Snapshot repository | 1510 B/event |
| Warm searchable cache | 705 B/event |
| Disk headroom | 1.3x |

These are placeholders until the real `events_2025_12_01` - `events_2026_01_30` run completes.

## Output

The calculator returns:

- Events per day.
- Raw TiB.
- Hot TiB.
- Cold TiB.
- Snapshot repository TiB.
- Warm cache TiB.
- Local cluster TiB before and after headroom.
- Suggested hot, cold, and warm node counts.

## How To Use After Real Dump Load

1. Run `scripts/preflight-real-dump.sh` for raw size.
2. Load a representative subset.
3. Run `scripts/run-real-retention-managed-ingest.sh` and summarize the generated CSV with `scripts/summarize-retention-metrics.sh`.
4. Replace calculator coefficients with measured values.
5. Recalculate the production EPS and retention target.

The calculator is an estimate, not a replacement for the final load test. Merge pressure, shard size, query mix, cache hit ratio, and snapshot repository latency must still be validated.
