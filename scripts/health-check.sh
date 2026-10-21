#!/usr/bin/env bash

URL=$1
TIMEOUT=$2

if [[ $# -lt 1 || $# -gt 2 || ! "$TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 <health-url> [timeout-seconds]" >&2
  exit 2
fi

metrics=$(curl --silent --show-error \
  --output /dev/null \
  --max-time "$TIMEOUT" \
  --write-out '%{http_code} %{time_total}' \
  "$URL")

curl_exit=$?

if [[ "$curl_exit" -ne 0 ]]; then
  echo "Health check failed: curl exit code $curl_exit; metrics: $metrics" >&2
  exit 1
fi

read -r status elapsed <<< "$metrics"
echo "HTTP $status | Response time: ${elapsed}s"

if [[ "$status" == "200" ]]; then
  exit 0
fi

exit 1