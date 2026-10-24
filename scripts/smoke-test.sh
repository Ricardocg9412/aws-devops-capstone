#!/usr/bin/env bash
# Repeatable HTTP checks against one inventory-api instance.
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 APPLICATION_URL" >&2
  exit 2
fi
case "$1" in
  http://?*|https://?*) ;;
  *) echo "APPLICATION_URL must start with http:// or https://" >&2; exit 2 ;;
esac
for dependency in curl jq; do
  command -v "$dependency" >/dev/null || {
    echo "Required command not found: $dependency" >&2
    exit 127
  }
done

base_url=${1%/}
asset_id="smoke-$(date +%s)-$$-$RANDOM-$RANDOM"
work_dir=$(mktemp -d)
created=false
cleanup() {
  local original_exit=$? cleanup_status
  trap - EXIT
  if [[ "$created" == true ]]; then
    if cleanup_status=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --request DELETE --output /dev/null --write-out '%{http_code}' \
      "$base_url/items/$asset_id"); then
      if [[ "$cleanup_status" != 204 && "$cleanup_status" != 404 ]]; then
        echo "Cleanup returned HTTP $cleanup_status for $asset_id" >&2
        if [[ "$original_exit" == 0 ]]; then original_exit=1; fi
      fi
    else
      echo "Cleanup request failed for $asset_id" >&2
      if [[ "$original_exit" == 0 ]]; then original_exit=1; fi
    fi
  fi
  rm -rf "$work_dir" || true
  exit "$original_exit"
}
trap cleanup EXIT

request() {
  local expected=$1 method=$2 path=$3 actual
  shift 3
  actual=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
    --request "$method" --output "$work_dir/response.json" \
    --write-out '%{http_code}' "$@" "$base_url$path")
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $method $path returned HTTP $actual; expected $expected" >&2
    cat "$work_dir/response.json" >&2
    exit 1
  fi
  echo "PASS: $method $path -> $actual"
}

payload=$(jq -n --arg id "$asset_id" '{id: $id, name: "ci-smoke-server", environment: "dev", type: "ec2", status: "running"}')
request 200 GET /health
jq -e '.status == "alive"' "$work_dir/response.json" >/dev/null
request 200 GET /ready
jq -e '.status == "ready"' "$work_dir/response.json" >/dev/null
request 201 POST /items --header 'Content-Type: application/json' --data-binary "$payload"
created=true
jq -e --argjson expected "$payload" '. == $expected' "$work_dir/response.json" >/dev/null
request 200 GET "/items/$asset_id"
jq -e --argjson expected "$payload" '. == $expected' "$work_dir/response.json" >/dev/null
request 409 POST /items --header 'Content-Type: application/json' --data-binary "$payload"
request 204 DELETE "/items/$asset_id"
created=false
if [[ -s "$work_dir/response.json" ]]; then
  echo "FAIL: DELETE returned a body with HTTP 204" >&2
  exit 1
fi
request 404 GET "/items/$asset_id"
echo "All smoke tests passed for $asset_id."
