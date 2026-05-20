#!/usr/bin/env bash
set -euo pipefail

cd /usr/share/opensearch

if [[ ! -f config/opensearch.keystore ]]; then
  bin/opensearch-keystore create
fi

if [[ -n "${S3_CLIENT_DEFAULT_ACCESS_KEY:-}" ]]; then
  printf '%s' "$S3_CLIENT_DEFAULT_ACCESS_KEY" | bin/opensearch-keystore add -f -x s3.client.default.access_key
fi

if [[ -n "${S3_CLIENT_DEFAULT_SECRET_KEY:-}" ]]; then
  printf '%s' "$S3_CLIENT_DEFAULT_SECRET_KEY" | bin/opensearch-keystore add -f -x s3.client.default.secret_key
fi

exec ./opensearch-docker-entrypoint.sh "$@"
