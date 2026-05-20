#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <elasticdump-data-file> <events-per-second> [stop-after-events] [index-prefix]" >&2
  exit 2
fi

dump_file="$1"
events_per_second="$2"
stop_after_events="${3:-}"
index_prefix="${4:-events}"

if [[ ! -f "$dump_file" ]]; then
  echo "Dump file not found: $dump_file" >&2
  exit 1
fi

compose=(docker compose -f docker-compose.yml -f docker-compose.server.yml)

export HOST_EVENTS_FILE="$(readlink -f "$dump_file")"
mkdir -p artifacts/rejected-events
export HOST_REJECTED_EVENTS_DIR="$(readlink -f artifacts/rejected-events)"

if [[ "${BUILD_EVENT_PRODUCER:-true}" == "true" ]]; then
  sudo -E "${compose[@]}" build event-producer
fi

env_args=(
  -e OpenSearchSettings__IndexPrefix="$index_prefix"
  -e Logging__LogLevel__System.Net.Http.HttpClient=Warning
  -e Logging__LogLevel__Microsoft.Hosting.Lifetime=Warning
  -e Producer__ReplayInputFile=true
  -e Producer__PreserveDateFields=true
  -e Producer__RejectedEventsDumpFilePath="/rejected/rejected-events.ndjson"
  -e Producer__DropEventsOutsideHotWindow=false
  -e Producer__EventsPerSecond="$events_per_second"
)

if [[ -n "$stop_after_events" && "$stop_after_events" != "0" ]]; then
  env_args+=(-e Producer__StopAfterEvents="$stop_after_events")
fi

sudo -E "${compose[@]}" run --rm --no-deps "${env_args[@]}" event-producer
