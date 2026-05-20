#!/usr/bin/env bash
set -euo pipefail

base_url="${OPENSEARCH_URL:-http://localhost:9200}"
policy_id="${ISM_POLICY_ID:-events-hot-cold-snapshot-10-10}"
policy_file="${ISM_POLICY_FILE:-opensearch/lifecycle/dataskope-ism-policy.hot-cold-snapshot-10-10.poc.json}"
template_name="${INDEX_TEMPLATE_NAME:-events-template}"
template_file="${INDEX_TEMPLATE_FILE:-opensearch/lifecycle/dataskope-index-template.loadtest.json}"
repo_name="${SNAPSHOT_REPOSITORY:-dataskope_lifecycle_repo}"
repo_file="${SNAPSHOT_REPOSITORY_FILE:-opensearch/lifecycle/snapshot-repository.s3-minio.json}"
expected_nodes="${EXPECTED_NODES:-3}"
timeout_seconds="${TIMEOUT_SECONDS:-240}"

json_get() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get(sys.argv[1], ""))' "$1"
}

deadline=$((SECONDS + timeout_seconds))
nodes=0
status=""
while (( SECONDS < deadline )); do
  if health="$(curl -fsS "$base_url/_cluster/health" 2>/dev/null)"; then
    status="$(printf '%s' "$health" | json_get status)"
    nodes="$(printf '%s' "$health" | json_get number_of_nodes)"
    if [[ "$status" == "green" || "$status" == "yellow" ]] && (( nodes >= expected_nodes )); then
      break
    fi
  fi
  echo "Waiting for OpenSearch... status=${status:-unknown} nodes=${nodes}/${expected_nodes}"
  sleep 5
done

if (( nodes < expected_nodes )); then
  echo "OpenSearch did not reach ${expected_nodes} nodes within ${timeout_seconds}s." >&2
  exit 1
fi

curl -fsS -X PUT "$base_url/_cluster/settings" \
  -H 'content-type: application/json' \
  -d '{"persistent":{"plugins":{"index_state_management":{"enabled":true,"job_interval":1,"jitter":0.0,"action_validation":{"enabled":false}}}}}' >/dev/null

curl -fsS -X PUT "$base_url/_snapshot/$repo_name" \
  -H 'content-type: application/json' \
  --data-binary "@$repo_file" >/dev/null

policy_status="$(curl -sS -o /tmp/os_poc_policy.json -w '%{http_code}' "$base_url/_plugins/_ism/policies/$policy_id")"
if [[ "$policy_status" == "200" ]]; then
  seq_no="$(python3 -c 'import json; print(json.load(open("/tmp/os_poc_policy.json"))["_seq_no"])')"
  primary_term="$(python3 -c 'import json; print(json.load(open("/tmp/os_poc_policy.json"))["_primary_term"])')"
  curl -fsS -X PUT "$base_url/_plugins/_ism/policies/$policy_id?if_seq_no=$seq_no&if_primary_term=$primary_term" \
    -H 'content-type: application/json' \
    --data-binary "@$policy_file" >/dev/null
else
  curl -fsS -X PUT "$base_url/_plugins/_ism/policies/$policy_id" \
    -H 'content-type: application/json' \
    --data-binary "@$policy_file" >/dev/null
fi

curl -fsS -X PUT "$base_url/_index_template/$template_name" \
  -H 'content-type: application/json' \
  --data-binary "@$template_file" >/dev/null

repo_verify_status="$(curl -sS -o /tmp/os_poc_repo_verify.json -w '%{http_code}' -X POST "$base_url/_snapshot/$repo_name/_verify")"
if [[ "$repo_verify_status" != "200" ]]; then
  echo "Snapshot repository verify failed. HTTP $repo_verify_status" >&2
  cat /tmp/os_poc_repo_verify.json >&2
  exit 1
fi

echo "Lifecycle bootstrap complete."
echo "nodes=$nodes status=$status"
echo "policy=$policy_id"
echo "template=$template_name"
echo "repository=$repo_name verified"
