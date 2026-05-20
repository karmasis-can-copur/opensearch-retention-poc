#!/usr/bin/env bash
set -euo pipefail

from_date="${1:-2025-12-01}"
to_date="${2:-2025-12-31}"
events_per_second="${3:-5000}"
dump_dir="${DUMP_DIR:-/}"
index_prefix="${INDEX_PREFIX:-events}"
ingest_mode="${INGEST_MODE:-bulk}"
bulk_workers="${BULK_WORKERS:-6}"
bulk_batch_docs="${BULK_BATCH_DOCS:-5000}"
hot_days="${HOT_DAYS:-10}"
cold_days="${COLD_DAYS:-10}"
stage_timeout_seconds="${STAGE_TIMEOUT_SECONDS:-7200}"
min_root_free_bytes="${MIN_ROOT_FREE_BYTES:-10737418240}"
min_data_free_bytes="${MIN_DATA_FREE_BYTES:-10737418240}"
base_url="${OPENSEARCH_URL:-http://localhost:9200}"
metrics_file="${METRICS_FILE:-artifacts/resource-metrics/real-retention-managed-$(date -u +%Y%m%d%H%M%S).csv}"

compose=(docker compose -f docker-compose.yml -f docker-compose.server.yml)
if ! docker ps >/dev/null 2>&1 && sudo -n docker ps >/dev/null 2>&1; then
  compose=(sudo -E docker compose -f docker-compose.yml -f docker-compose.server.yml)
fi

free_bytes() {
  df -B1 "$1" | awk 'NR==2 {print $4}'
}

check_disk() {
  root_free="$(free_bytes /)"
  data_free="$(free_bytes /data)"
  echo "disk.root_free_bytes=$root_free"
  echo "disk.data_free_bytes=$data_free"
  if (( root_free < min_root_free_bytes )); then
    echo "Root disk free space is below safety threshold." >&2
    exit 1
  fi
  if (( data_free < min_data_free_bytes )); then
    echo "/data free space is below safety threshold." >&2
    exit 1
  fi
}

index_stats() {
  local index="$1"
  curl -fsS "$base_url/$index/_stats/store,docs?filter_path=indices.*.primaries.store.size_in_bytes,indices.*.primaries.docs.count" 2>/dev/null |
    python3 -c 'import json,sys; data=json.load(sys.stdin); indices=data.get("indices", {}); item=next(iter(indices.values()), {}); prim=item.get("primaries", {}); docs=prim.get("docs", {}).get("count", 0); store=prim.get("store", {}).get("size_in_bytes", 0); print(f"{docs},{store}")'
}

minio_bytes() {
  if [[ -d /data/minio ]]; then
    du -sb /data/minio | awk '{print $1}'
  else
    echo 0
  fi
}

stage_for_date() {
  local day="$1"
  local day_epoch now_epoch age_days
  day_epoch="$(date -u -d "$day" +%s)"
  now_epoch="$(date -u +%s)"
  age_days=$(( (now_epoch - day_epoch) / 86400 ))
  if (( age_days < hot_days )); then
    echo "hot"
  elif (( age_days < hot_days + cold_days )); then
    echo "cold"
  else
    echo "searchable_snapshot"
  fi
}

wait_for_stage() {
  local index="$1"
  local stage="$2"
  local remote_index="remote_${index}"
  local deadline=$((SECONDS + stage_timeout_seconds))

  echo "Waiting for lifecycle stage. index=$index expected=$stage timeout=${stage_timeout_seconds}s"
  while (( SECONDS < deadline )); do
    case "$stage" in
      hot)
        if curl -fsS "$base_url/_cat/indices/$index?h=index" 2>/dev/null | grep -qx "$index"; then
          echo "stage_ready=$stage index=$index"
          return
        fi
        ;;
      cold)
        if curl -fsS "$base_url/_cat/shards/$index?h=node" 2>/dev/null | grep -q '^opensearch-cold$'; then
          if ! curl -fsS "$base_url/_cat/shards/$index?h=node" 2>/dev/null | grep -vq '^opensearch-cold$'; then
            echo "stage_ready=$stage index=$index"
            return
          fi
        fi
        ;;
      searchable_snapshot)
        if curl -fsS "$base_url/_cat/indices/$remote_index?h=index" 2>/dev/null | grep -qx "$remote_index"; then
          if ! curl -fsS "$base_url/_cat/indices/$index?h=index" 2>/dev/null | grep -qx "$index"; then
            echo "stage_ready=$stage index=$remote_index"
            return
          fi
        fi
        ;;
    esac
    sleep 30
  done

  echo "Timed out waiting for stage=$stage index=$index" >&2
  curl -sS "$base_url/_plugins/_ism/explain/$index?pretty" || true
  exit 1
}

mkdir -p "$(dirname "$metrics_file")"
if [[ ! -f "$metrics_file" ]]; then
  echo "date,index,expected_stage,raw_bytes,hot_docs,hot_store_bytes,final_index,final_stage,final_docs,final_store_bytes,minio_bytes,root_free_bytes,data_free_bytes" > "$metrics_file"
fi

if [[ "$ingest_mode" == "producer" ]]; then
  "${compose[@]}" build event-producer
fi

current="$from_date"
while [[ "$current" < "$(date -u -d "$to_date + 1 day" +%F)" ]]; do
  index="$(date -u -d "$current" +${index_prefix}_%Y_%m_%d)"
  file="${dump_dir%/}/${index}.data.json"
  expected_stage="$(stage_for_date "$current")"

  if [[ ! -s "$file" ]]; then
    echo "Missing or empty dump file: $file" >&2
    exit 1
  fi

  echo ""
  echo "=== $current / $index / expected=$expected_stage ==="
  check_disk
  "${compose[@]}" stop ism-policy-reconciler >/dev/null
  if [[ "$ingest_mode" == "bulk" ]]; then
    python3 ./scripts/fast-elasticdump-replay.py "$file" "$index" \
      --url "$base_url" \
      --workers "$bulk_workers" \
      --batch-docs "$bulk_batch_docs" \
      --refresh
  else
    BUILD_EVENT_PRODUCER=false ./scripts/remote-run-dump-replay.sh "$file" "$events_per_second" 0 "$index_prefix"
  fi
  curl -fsS -X POST "$base_url/$index/_refresh" >/dev/null
  IFS=',' read -r hot_docs hot_store_bytes < <(index_stats "$index")
  raw_bytes="$(stat -c '%s' "$file")"
  echo "hot_checkpoint index=$index docs=$hot_docs store_bytes=$hot_store_bytes raw_bytes=$raw_bytes"
  "${compose[@]}" start ism-policy-reconciler >/dev/null
  wait_for_stage "$index" "$expected_stage"
  final_index="$index"
  if [[ "$expected_stage" == "searchable_snapshot" ]]; then
    final_index="remote_${index}"
  fi
  IFS=',' read -r final_docs final_store_bytes < <(index_stats "$final_index")
  root_free="$(free_bytes /)"
  data_free="$(free_bytes /data)"
  repo_bytes="$(minio_bytes)"
  echo "$current,$index,$expected_stage,$raw_bytes,$hot_docs,$hot_store_bytes,$final_index,$expected_stage,$final_docs,$final_store_bytes,$repo_bytes,$root_free,$data_free" >> "$metrics_file"
  echo "final_checkpoint index=$final_index docs=$final_docs store_bytes=$final_store_bytes minio_bytes=$repo_bytes"
  check_disk
  current="$(date -u -d "$current + 1 day" +%F)"
done

echo ""
echo "Managed ingest complete. from=$from_date to=$to_date eps=$events_per_second"
echo "metrics_file=$metrics_file"
