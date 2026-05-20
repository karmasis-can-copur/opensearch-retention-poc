#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <sample-file> <events-per-second> <stop-after-events> [index-prefix]" >&2
  exit 2
fi

sample_file="$1"
events_per_second="$2"
stop_after_events="$3"
index_prefix="${4:-events}"

compose=(docker compose -f docker-compose.yml -f docker-compose.server.yml)

if [[ ! -f "$sample_file" ]]; then
  echo "Sample file not found: $sample_file" >&2
  exit 1
fi

export HOST_EVENTS_FILE="$(readlink -f "$sample_file")"
mkdir -p artifacts/rejected-events
export HOST_REJECTED_EVENTS_DIR="$(readlink -f artifacts/rejected-events)"

if [[ "${BUILD_EVENT_PRODUCER:-true}" == "true" ]]; then
  sudo -E "${compose[@]}" build event-producer
fi

producer_hot_window_days="${PRODUCER_HOT_WINDOW_DAYS:-30}"
producer_drop_outside_hot_window="${PRODUCER_DROP_OUTSIDE_HOT_WINDOW:-true}"

sudo -E "${compose[@]}" run --rm --no-deps \
  -e OpenSearchSettings__IndexPrefix="$index_prefix" \
  -e Logging__LogLevel__System.Net.Http.HttpClient=Warning \
  -e Logging__LogLevel__Microsoft.Hosting.Lifetime=Warning \
  -e Producer__RejectedEventsDumpFilePath="/rejected/rejected-events.ndjson" \
  -e Producer__DropEventsOutsideHotWindow="$producer_drop_outside_hot_window" \
  -e Producer__HotWindowDays="$producer_hot_window_days" \
  -e Producer__EventsPerSecond="$events_per_second" \
  -e Producer__StopAfterEvents="$stop_after_events" \
  event-producer
