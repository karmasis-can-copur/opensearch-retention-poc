#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example. Review MinIO values before production-like runs."
fi

mkdir -p artifacts/rejected-events

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

docker compose -f docker-compose.yml -f docker-compose.server.yml up -d --build "${services[@]}"

echo ""
echo "PoC stack started."
echo "OpenSearch: http://localhost:9200"
echo "Dashboard:  http://localhost:9205"
echo "MinIO:      http://localhost:9001"
