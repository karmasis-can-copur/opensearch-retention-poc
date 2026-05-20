#!/usr/bin/env sh
set -eu

base_url="${OPENSEARCH_URL:-http://opensearch-hot:9200}"
policy_id="${ISM_POLICY_ID:-events-hot-snapshot}"
index_prefix="${INDEX_PREFIX:-events}"
interval_seconds="${ISM_RECONCILE_INTERVAL_SECONDS:-60}"
run_once="${ISM_RECONCILE_ONCE:-false}"

reconcile_once() {
  if ! curl -fsS "$base_url/_cluster/health" >/dev/null; then
    echo "OpenSearch is not ready yet."
    return 0
  fi

  indices="$(curl -fsS "$base_url/_cat/indices/${index_prefix}_*?h=index&s=index" || true)"
  for index_name in $indices; do
    case "$index_name" in
      ${index_prefix}_[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9])
        ;;
      *)
        continue
        ;;
    esac

    explain="$(curl -fsS "$base_url/_plugins/_ism/explain/$index_name" || true)"
    if echo "$explain" | grep -Eq '"policy_id"[[:space:]]*:[[:space:]]*"[^"]+"'; then
      continue
    fi

    echo "Attaching ISM policy '$policy_id' to '$index_name'."
    curl -fsS -XPOST "$base_url/_plugins/_ism/add/$index_name" \
      -H "Content-Type: application/json" \
      -d "{\"policy_id\":\"$policy_id\"}" >/dev/null || true
  done
}

while :; do
  reconcile_once

  if [ "$run_once" = "true" ]; then
    break
  fi

  sleep "$interval_seconds"
done
