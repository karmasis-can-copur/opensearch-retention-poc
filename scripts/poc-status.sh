#!/usr/bin/env bash
set -euo pipefail

opensearch_url="${OPENSEARCH_URL:-http://localhost:9200}"
dashboard_url="${DASHBOARD_URL:-http://localhost:9205}"
minio_data_dir="${MINIO_DATA_DIR:-/data/minio}"
docker_cmd=(docker)
if ! docker ps >/dev/null 2>&1 && sudo -n docker ps >/dev/null 2>&1; then
  docker_cmd=(sudo docker)
fi

echo "== Cluster health =="
curl -fsS "$opensearch_url/_cat/health?v" || true

echo ""
echo "== OpenSearch nodes =="
curl -fsS "$opensearch_url/_cat/nodes?v&h=name,node.role,heap.percent,ram.percent,cpu,disk.used,disk.avail,disk.percent" || true

echo ""
echo "== Retention summary =="
if retention_json="$(curl -fsS "$dashboard_url/api/retention/indices" 2>/dev/null)"; then
  RETENTION_JSON="$retention_json" python3 - <<'PY'
import json
import os

def fmt_bytes(value):
    value = float(value or 0)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit = 0
    while value >= 1024 and unit < len(units) - 1:
        value /= 1024
        unit += 1
    return f"{value:.2f} {units[unit]}" if unit else f"{int(value)} B"

data = json.loads(os.environ["RETENTION_JSON"])
stages = {item["stage"]: item for item in data.get("stages", [])}
print(f"{'stage':24} {'indexes':>7} {'docs':>14} {'store':>14}")
for name in ["hot", "cold", "searchable_snapshot", "unknown"]:
    item = stages.get(name)
    if not item:
        continue
    print(f"{name:24} {item['indexes']:7} {item['docs']:14,} {fmt_bytes(item['storeBytes']):>14}")

indices = sorted(data.get("indices", []), key=lambda x: x.get("name", ""))[-8:]
if indices:
    print("")
    print("last indexes:")
    for item in indices:
        print(f"{item['name']:34} {item['stage']:20} {item['docs']:12,} {fmt_bytes(item['storeBytes']):>12}")
PY
else
  curl -fsS "$opensearch_url/_cat/indices/events_*,remote_events_*?v&h=health,index,docs.count,store.size" || true
fi

echo ""
echo "== Container resources =="
"${docker_cmd[@]}" stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}" 2>/dev/null \
  | awk 'NR==1 || /opensearch-|dataskope-minio|retention-dashboard/' || true

echo ""
echo "== Host disk =="
df -h / /data 2>/dev/null || df -h /
if [[ -d "$minio_data_dir" ]]; then
  du -sh "$minio_data_dir" 2>/dev/null | awk '{print "minio_repo=" $1 " path=" $2}'
fi
