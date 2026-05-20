#!/usr/bin/env bash
set -euo pipefail

metrics_file="${1:?Usage: $0 <metrics-csv>}"

python3 - "$metrics_file" <<'PY'
import csv
import sys

def fmt_bytes(value):
    value = float(value or 0)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit = 0
    while value >= 1024 and unit < len(units) - 1:
        value /= 1024
        unit += 1
    return f"{value:.2f} {units[unit]}" if unit else f"{int(value)} B"

path = sys.argv[1]
rows = list(csv.DictReader(open(path, newline="")))
if not rows:
    raise SystemExit("No metric rows found.")

hot_store = sum(int(row["hot_store_bytes"]) for row in rows)
final_store = sum(int(row["final_store_bytes"]) for row in rows)
raw = sum(int(row["raw_bytes"]) for row in rows)
docs = sum(int(row["hot_docs"]) for row in rows)
repo = max(int(row["minio_bytes"]) for row in rows)
root_free = int(rows[-1]["root_free_bytes"])
data_free = int(rows[-1]["data_free_bytes"])
stages = {}
for row in rows:
    stages.setdefault(row["final_stage"], {"days": 0, "docs": 0, "store": 0})
    stages[row["final_stage"]]["days"] += 1
    stages[row["final_stage"]]["docs"] += int(row["final_docs"])
    stages[row["final_stage"]]["store"] += int(row["final_store_bytes"])

print("== Retention metric summary ==")
print(f"days={len(rows)} docs={docs:,} raw={fmt_bytes(raw)}")
print(f"all_hot_logical_store={fmt_bytes(hot_store)}")
print(f"final_local_logical_store={fmt_bytes(final_store)}")
print(f"snapshot_repository_size={fmt_bytes(repo)}")
print(f"root_free_after={fmt_bytes(root_free)}")
print(f"data_free_after={fmt_bytes(data_free)}")
print("")
print("stage,days,docs,logical_store")
for stage, item in sorted(stages.items()):
    print(f"{stage},{item['days']},{item['docs']},{fmt_bytes(item['store'])}")
PY
