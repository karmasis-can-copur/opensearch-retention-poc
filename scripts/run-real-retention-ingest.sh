#!/usr/bin/env bash
set -euo pipefail

from_date="${1:-2025-12-01}"
to_date="${2:-2026-01-30}"
events_per_second="${3:-5000}"
dump_dir="${DUMP_DIR:-/}"
index_prefix="${INDEX_PREFIX:-events}"

current="$from_date"
while [[ "$current" < "$(date -u -d "$to_date + 1 day" +%F)" ]]; do
  index="$(date -u -d "$current" +events_%Y_%m_%d)"
  file="${dump_dir%/}/${index}.data.json"

  if [[ ! -f "$file" ]]; then
    echo "Missing dump file: $file" >&2
    exit 1
  fi

  if [[ ! -s "$file" ]]; then
    echo "Dump file is empty: $file" >&2
    exit 1
  fi

  echo "Replaying $file into OpenSearch at target ${events_per_second} EPS."
  BUILD_EVENT_PRODUCER=false ./scripts/remote-run-dump-replay.sh "$file" "$events_per_second" 0 "$index_prefix"
  current="$(date -u -d "$current + 1 day" +%F)"
done
