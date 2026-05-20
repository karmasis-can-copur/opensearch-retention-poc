# Search Guidelines

The retention dashboard exposes only safe search templates. Use the examples below as guardrails for manual tests.

## Good On Hot

Hot indexes are the active search tier. These are acceptable:

- Date-bounded searches on `TimeCreated`.
- `size=0` count queries.
- Small `terms` aggregations on numeric/keyword fields.
- Small sample queries, for example `size <= 25`.
- Targeting exact daily indexes instead of broad wildcards.

Example:

```json
{
  "size": 0,
  "track_total_hits": true,
  "query": {
    "range": {
      "TimeCreated": {
        "gte": "2026-01-30T00:00:00Z",
        "lte": "2026-01-30T23:59:59Z"
      }
    }
  }
}
```

## Acceptable On Cold

Cold indexes are local full copies, but read-only and force-merged. Prefer:

- Date-bounded counts.
- Narrow exact-day searches.
- Small aggregations.
- Warmup before comparing latency.

Avoid running cold force-merge/relocation during hot ingest peak windows.

## Acceptable On Searchable Snapshot

Searchable snapshot indexes are queryable, but the primary data source is the snapshot repository. Local warm-node disk is cache/metadata.

Prefer:

- `size=0` counts.
- Date-bounded queries.
- Small sample fetches.
- Repeated warmed queries when comparing performance.

Expect first-query latency to be worse if cache is cold or if the repository is slow.

## Avoid

Avoid these on cold/searchable snapshot unless specifically load testing:

- Leading wildcard text queries such as `*admin`.
- Broad `query_string` over many fields.
- Deep pagination with large `from`.
- Large `size` exports.
- High-cardinality aggregations over broad date ranges.
- Cross-stage wildcard searches without a date range.

Use the dashboard's safe templates first; add manual heavy queries only as explicit performance-test scenarios.
