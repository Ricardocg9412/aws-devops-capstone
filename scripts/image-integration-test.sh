#!/usr/bin/env bash
# Tests an already-loaded image; never builds, pulls, or publishes it.
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 IMAGE_REFERENCE" >&2
  exit 2
fi

container_id=""
cleanup() {
  local check_exit=$?
  if [[ -n "$container_id" ]]; then
    docker logs "$container_id" || true
    docker rm -f "$container_id" >/dev/null || true
  fi
  exit "$check_exit"
}
trap cleanup EXIT

container_id=$(docker run --detach --pull=never \
  --publish 127.0.0.1::8080 \
  --user 10001:10001 --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=33554432,mode=1777 \
  --env INVENTORY_UNREADY_FILE=/tmp/inventory-api.unready "$1")
host_port=$(docker port "$container_id" 8080/tcp)
base_url="http://$host_port"

healthy=false
for _ in {1..30}; do
  if curl --fail --silent --max-time 2 "$base_url/health" >/dev/null; then
    healthy=true
    break
  fi
  sleep 1
done
if [[ "$healthy" != true ]]; then
  echo "Container did not become healthy within the startup window." >&2
  exit 1
fi

expect_status() {
  local expected=$1 path=$2 actual
  actual=$(curl --silent --show-error --max-time 5 --output /dev/null \
    --write-out '%{http_code}' "$base_url$path")
  if [[ "$actual" != "$expected" ]]; then
    echo "$path returned $actual; expected $expected" >&2
    exit 1
  fi
}

expect_status 200 /health
expect_status 200 /ready
expect_status 200 /openapi.json
docker exec "$container_id" python -c \
  'from pathlib import Path; Path("/tmp/inventory-api.unready").touch()'
expect_status 503 /ready
expect_status 200 /health
docker exec "$container_id" python -c \
  'from pathlib import Path; Path("/tmp/inventory-api.unready").unlink()'
expect_status 200 /ready
echo "Container integration checks passed."
