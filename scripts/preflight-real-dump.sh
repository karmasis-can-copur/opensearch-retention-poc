#!/usr/bin/env bash
set -euo pipefail

from_date="${1:-2025-12-01}"
to_date="${2:-2026-01-30}"
dump_dir="${DUMP_DIR:-/}"
count_lines="${COUNT_LINES:-false}"
show_days="${SHOW_DAYS:-false}"
hot_days="${HOT_DAYS:-10}"
cold_days="${COLD_DAYS:-10}"

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
hot_raw=0
cold_raw=0
snapshot_raw=0
hot_files=0
cold_files=0
snapshot_files=0
missing=0
files=0
line_total=0
current="$from_date"
to_epoch="$(date -u -d "$to_date" +%s)"

if [[ "$show_days" == "true" ]]; then
  echo "date,index,stage,file,raw_bytes,lines"
fi
while [[ "$current" < "$(date -u -d "$to_date + 1 day" +%F)" ]]; do
  index="$(date_to_index "$current")"
  file="${dump_dir%/}/${index}.data.json"
  raw_bytes=0
  lines=""
  current_epoch="$(date -u -d "$current" +%s)"
  days_from_end=$(( (to_epoch - current_epoch) / 86400 ))
  if (( days_from_end < hot_days )); then
    stage="hot"
  elif (( days_from_end < hot_days + cold_days )); then
    stage="cold"
  else
    stage="searchable_snapshot"
  fi

  if [[ ! -f "$file" ]]; then
    missing=$((missing + 1))
  else
    files=$((files + 1))
    raw_bytes="$(stat -c '%s' "$file")"
    sum_raw=$((sum_raw + raw_bytes))
    case "$stage" in
      hot)
        hot_raw=$((hot_raw + raw_bytes))
        hot_files=$((hot_files + 1))
        ;;
      cold)
        cold_raw=$((cold_raw + raw_bytes))
        cold_files=$((cold_files + 1))
        ;;
      searchable_snapshot)
        snapshot_raw=$((snapshot_raw + raw_bytes))
        snapshot_files=$((snapshot_files + 1))
        ;;
    esac
    if [[ "$count_lines" == "true" ]]; then
      lines="$(wc -l < "$file")"
      line_total=$((line_total + lines))
    fi
  fi

  if [[ "$show_days" == "true" ]]; then
    echo "$current,$index,$stage,$file,$raw_bytes,$lines"
  fi
  current="$(date -u -d "$current + 1 day" +%F)"
done

hot_est="$(to_bytes "$(awk -v raw="$hot_raw" -v factor="$hot_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
cold_est="$(to_bytes "$(awk -v raw="$cold_raw" -v factor="$cold_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
snapshot_est="$(to_bytes "$(awk -v raw="$snapshot_raw" -v factor="$snapshot_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
warm_est="$(to_bytes "$(awk -v raw="$snapshot_raw" -v factor="$warm_cache_bytes_per_raw_byte" 'BEGIN { print raw * factor }')")"
local_est="$(to_bytes "$(awk -v hot="$hot_est" -v cold="$cold_est" -v warm="$warm_est" -v factor="$headroom" 'BEGIN { print (hot + cold + warm) * factor }')")"

echo ""
echo "summary.files=$files"
echo "summary.missing=$missing"
echo "summary.hot_days=$hot_days"
echo "summary.cold_days=$cold_days"
echo "summary.raw_bytes=$sum_raw"
echo "summary.hot_files=$hot_files"
echo "summary.hot_raw_bytes=$hot_raw"
echo "summary.cold_files=$cold_files"
echo "summary.cold_raw_bytes=$cold_raw"
echo "summary.searchable_snapshot_files=$snapshot_files"
echo "summary.searchable_snapshot_raw_bytes=$snapshot_raw"
echo "summary.lines=$line_total"
echo "estimate.hot_bytes=$hot_est"
echo "estimate.cold_bytes=$cold_est"
echo "estimate.snapshot_repo_bytes=$snapshot_est"
echo "estimate.warm_cache_bytes=$warm_est"
echo "estimate.local_cluster_with_headroom_bytes=$local_est"
echo ""
echo "df.root=$(df -B1 / | awk 'NR==2 {print $4}')"
echo "df.data=$(df -B1 /data | awk 'NR==2 {print $4}')"
