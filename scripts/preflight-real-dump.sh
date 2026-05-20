#!/usr/bin/env bash
set -euo pipefail

from_date="${1:-2025-12-01}"
to_date="${2:-2026-01-30}"
dump_dir="${DUMP_DIR:-/}"
count_lines="${COUNT_LINES:-false}"

hot_bytes_per_raw_byte="${HOT_BYTES_PER_RAW_BYTE:-1.52}"
cold_bytes_per_raw_byte="${COLD_BYTES_PER_RAW_BYTE:-1.43}"
snapshot_bytes_per_raw_byte="${SNAPSHOT_BYTES_PER_RAW_BYTE:-1.43}"
warm_cache_bytes_per_raw_byte="${WARM_CACHE_BYTES_PER_RAW_BYTE:-0.67}"
headroom="${DISK_HEADROOM_FACTOR:-1.30}"

date_to_index() {
  date -u -d "$1" +events_%Y_%m_%d
}

to_bytes() {
  awk -v value="$1" 'BEGIN { printf "%.0f", value }'
}

sum_raw=0
missing=0
not_done=0
files=0
line_total=0
current="$from_date"

echo "date,index,file,done,raw_bytes,lines"
while [[ "$current" < "$(date -u -d "$to_date + 1 day" +%F)" ]]; do
  index="$(date_to_index "$current")"
  file="${dump_dir%/}/${index}.data.json"
  done_file="$file.done"
  raw_bytes=0
  lines=""
  done="false"

  if [[ ! -f "$file" ]]; then
    missing=$((missing + 1))
  else
    files=$((files + 1))
    raw_bytes="$(stat -c '%s' "$file")"
    sum_raw=$((sum_raw + raw_bytes))
    if [[ "$count_lines" == "true" ]]; then
      lines="$(wc -l < "$file")"
      line_total=$((line_total + lines))
    fi
  fi

  if [[ -f "$done_file" ]]; then
    done="true"
  else
    not_done=$((not_done + 1))
  fi

  echo "$current,$index,$file,$done,$raw_bytes,$lines"
  current="$(date -u -d "$current + 1 day" +%F)"
done

hot_est="$(to_bytes "$(awk -v raw="$sum_raw" -v factor="$hot_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
cold_est="$(to_bytes "$(awk -v raw="$sum_raw" -v factor="$cold_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
snapshot_est="$(to_bytes "$(awk -v raw="$sum_raw" -v factor="$snapshot_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
warm_est="$(to_bytes "$(awk -v raw="$sum_raw" -v factor="$warm_cache_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
local_est="$(to_bytes "$(awk -v hot="$hot_est" -v cold="$cold_est" -v warm="$warm_est" -v factor="$headroom" 'BEGIN { print (hot + cold + warm) * factor }')")"

echo ""
echo "summary.files=$files"
echo "summary.missing=$missing"
echo "summary.not_done=$not_done"
echo "summary.raw_bytes=$sum_raw"
echo "summary.lines=$line_total"
echo "estimate.hot_bytes=$hot_est"
echo "estimate.cold_bytes=$cold_est"
echo "estimate.snapshot_repo_bytes=$snapshot_est"
echo "estimate.warm_cache_bytes=$warm_est"
echo "estimate.local_cluster_with_headroom_bytes=$local_est"
echo ""
echo "df.root=$(df -B1 / | awk 'NR==2 {print $4}')"
echo "df.data=$(df -B1 /data | awk 'NR==2 {print $4}')"
