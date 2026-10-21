#!/usr/bin/env bash

if [[ $# -ne 1 || -z "$1" || "$1" == -* ]]; then
  echo "Usage: $0 <container-name-or-id>" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker CLI is not installed or is not on PATH." >&2
  exit 1
fi

container="$1"

# Inspect once so the report uses one snapshot of the container metadata.
if ! metadata=$(docker inspect --type container --format \
  '{{.Id}}
{{.State.Status}}
{{.State.Running}}
{{if .State.Health}}{{.State.Health.Status}}{{else}}not configured{{end}}
{{.Config.Image}}
{{if .Config.User}}{{.Config.User}}{{else}}root (default){{end}}
{{.RestartCount}}' "$container" 2>&1); then
  echo "Error: Cannot inspect container '$container'. It may not exist, or Docker may be unavailable." >&2
  printf '%s\n' "$metadata" >&2
  exit 1
fi

# Use the resolved ID for subsequent calls, even if the container is renamed.
{
  IFS= read -r container_id
  IFS= read -r state
  IFS= read -r running
  IFS= read -r health
  IFS= read -r image
  IFS= read -r runtime_user
  IFS= read -r restarts
} <<< "$metadata"

printf '\nContainer Report: %s\n' "$container"
printf '%s\n' '----------------------'
printf 'Container ID: %s\n' "$container_id"
printf 'Container state: %s\n' "$state"
printf 'Container running: %s\n' "$running"
printf 'Container health: %s\n' "$health"
printf 'Container image: %s\n' "$image"
printf 'Container user (configured): %s\n' "$runtime_user"
printf 'Restart count: %s\n' "$restarts"

result=0
printf '\nResource usage:\n'
if [[ "$running" == true ]]; then
  if ! docker stats --no-stream --format \
    'CPU: {{.CPUPerc}} | Memory: {{.MemUsage}} ({{.MemPerc}})' "$container_id"; then
    echo "Error: Unable to collect container resource usage." >&2
    result=1
  fi
else
  echo "CPU and memory: unavailable (container is not running)"
fi

printf '\nLast 20 log lines:\n'
if ! docker logs --tail 20 "$container_id" 2>&1; then
  echo "Error: Unable to retrieve container logs." >&2
  result=1
fi

exit "$result"
