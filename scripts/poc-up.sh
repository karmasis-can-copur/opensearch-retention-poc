#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example. Review MinIO values before production-like runs."
fi

mkdir -p artifacts/rejected-events

docker_cmd=(docker)
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1; then
    docker_cmd=(sudo docker)
  else
    echo "Docker is not accessible. Add the user to docker group or run with sudo." >&2
    exit 1
  fi
fi

services=(
  minio
  minio-init
  opensearch-hot
  opensearch-cold
  opensearch-search
  opensearch-dashboards
  retention-dashboard
  ism-policy-reconciler
)

"${docker_cmd[@]}" compose -f docker-compose.yml -f docker-compose.server.yml up -d --build "${services[@]}"

echo ""
echo "PoC stack started."
echo "OpenSearch: http://localhost:9200"
echo "Dashboard:  http://localhost:9205"
echo "MinIO:      http://localhost:9001"
