#!/usr/bin/env bash
# Best-effort, release-scoped evidence. Never fetch Secrets or dump environment.
set -Eeuo pipefail
umask 077
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 NAMESPACE HELM_RELEASE" >&2
  echo "Optional: KUBE_CONTEXT and DIAGNOSTICS_DIR (parent directory)." >&2
  exit 2
fi
namespace=$1
release=$2
for value in "$namespace" "$release"; do
  if [[ ! "$value" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo "Namespace and release must be Kubernetes-style names." >&2
    exit 2
  fi
done
command -v jq >/dev/null || { echo "jq is required" >&2; exit 127; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
parent=${DIAGNOSTICS_DIR:-diagnostics}
mkdir -p "$parent"
output=$(mktemp -d "$parent/$(date -u +%Y%m%dT%H%M%SZ)-$namespace-$release.XXXXXX")
printf 'Diagnostics directory: %s\n' "$output"
printf 'file\texit_code\n' > "$output/collection-status.tsv"
printf 'namespace=%s\nrelease=%s\ncollected_at=%s\nlog_tail_per_container=1000\n' \
  "$namespace" "$release" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$output/scope.txt"
kube=(kubectl --request-timeout=10s --namespace "$namespace")
helm_cmd=(helm --namespace "$namespace")
if [[ -n ${KUBE_CONTEXT:-} ]]; then
  kube+=(--context "$KUBE_CONTEXT")
  helm_cmd+=(--kube-context "$KUBE_CONTEXT")
fi
selector="app.kubernetes.io/instance=$release"

# Every command records its own failure; unavailable evidence cannot stop others.
capture() {
  local file=$1 result=0
  shift
  if "$@" > "$output/$file" 2> "$output/$file.stderr"; then
    result=0
  else
    result=$?
    printf 'Unavailable: %s (exit %s); continuing.\n' "$file" "$result" >&2
  fi
  printf '%s\t%s\n' "$file" "$result" >> "$output/collection-status.tsv"
  return 0
}

pods_snapshot() {
  "${kube[@]}" get pods -l "$selector" -o json | jq '
    def state_summary:
      if .waiting then {waiting: (.waiting | {reason, message})}
      elif .terminated then {terminated: (.terminated | {reason, exitCode, signal, startedAt, finishedAt})}
      elif .running then {running: (.running | {startedAt})} else {} end;
    def probe_summary:
      if . == null then null else
        {httpGet: (if .httpGet then (.httpGet | {path, port, scheme}) else null end),
         tcpSocket: (if .tcpSocket then (.tcpSocket | {port}) else null end),
         exec: has("exec"), initialDelaySeconds, periodSeconds, timeoutSeconds, failureThreshold}
      end;
    {items: [.items[] | {
      name: .metadata.name, namespace: .metadata.namespace,
      created_at: .metadata.creationTimestamp, node: .spec.nodeName,
      phase: .status.phase, reason: .status.reason,
      conditions: [.status.conditions[]? | {type, status, reason, message, lastTransitionTime}],
      containers: [(.spec.initContainers[]?, .spec.containers[]?, .spec.ephemeralContainers[]?) |
        {name, image, imagePullPolicy, resources, securityContext,
         readinessProbe: (.readinessProbe | probe_summary),
         livenessProbe: (.livenessProbe | probe_summary)}],
      container_statuses: [(.status.initContainerStatuses[]?, .status.containerStatuses[]?, .status.ephemeralContainerStatuses[]?) |
        {name, ready, started, restartCount, image, imageID,
         state: (.state | state_summary), lastState: (.lastState | state_summary)}]
    }]}'
}
readiness_summary() {
  jq '[.items[] | {pod: .name, node, phase,
    ready: ([.conditions[] | select(.type == "Ready") | .status][0] // "Unknown"),
    containers: [.container_statuses[] | {name, ready, restartCount, state, lastState}]}]' "$output/pods.json"
}
pod_descriptions() {
  # Describe from an allowlisted snapshot: raw kubectl describe prints env values.
  jq -r '.items[] |
    "Pod: \(.namespace)/\(.name)\nNode: \(.node // "unassigned")\nPhase: \(.phase // "Unknown")",
    (.conditions[] | "Condition \(.type): \(.status) (\(.reason // "")) \(.message // "")"),
    (.containers[] | "Container \(.name): image=\(.image) pullPolicy=\(.imagePullPolicy) resources=\(.resources | tojson) readinessProbe=\(.readinessProbe | tojson)"),
    (.container_statuses[] | "Status \(.name): ready=\(.ready) restarts=\(.restartCount) state=\(.state | tojson) lastState=\(.lastState | tojson)"), ""' "$output/pods.json"
}
deployments_snapshot() {
  "${kube[@]}" get deployments -l "$selector" -o json | jq '{items: [.items[] |
    {name: .metadata.name, generation: .metadata.generation, desired_replicas: .spec.replicas,
     containers: [.spec.template.spec.containers[] | {name, image, resources}],
     status: (.status | {observedGeneration, replicas, updatedReplicas, readyReplicas, availableReplicas, unavailableReplicas, conditions})}]}'
}
events_snapshot() {
  "${kube[@]}" get events -o json | jq '[.items[] |
    {time: (.lastTimestamp // .eventTime // .metadata.creationTimestamp), type, reason,
     object: (.involvedObject | {kind, name}), count, message}] | sort_by(.time)'
}
helm_status() {
  # Raw Helm JSON can contain values, manifests, notes, and embedded Secrets.
  "${helm_cmd[@]}" status "$release" -o json | jq '{name, namespace, revision: .version,
    status: .info.status, first_deployed: .info.first_deployed, last_deployed: .info.last_deployed,
    chart: (.chart.metadata | {name, version, appVersion})}'
}
helm_history() {
  "${helm_cmd[@]}" history "$release" --max 10 -o json | jq '[.[] | {revision, updated, status, chart, app_version}]'
}
services_snapshot() {
  "${kube[@]}" get services -l "$selector" -o json | jq '{items: [.items[] |
    {name: .metadata.name, type: .spec.type, clusterIP: .spec.clusterIP, ports: .spec.ports, selector: .spec.selector}]}'
}
endpoints_snapshot() {
  "${kube[@]}" get endpointslices -l "kubernetes.io/service-name=$1" -o json | jq '{items: [.items[] |
    {name: .metadata.name, ports, endpoints: [.endpoints[]? | {addresses, conditions, targetRef: (.targetRef | {kind, name})}]}]}'
}
node_snapshot() {
  "${kube[@]}" get node "$1" -o json | jq '{name: .metadata.name,
    unschedulable: .spec.unschedulable, taints: .spec.taints,
    capacity: .status.capacity, allocatable: .status.allocatable,
    conditions: [.status.conditions[]? | {type, status, reason, message}]}'
}
container_logs() {
  # Retain JSON and startup/traceback lines, with common credentials redacted.
  "${kube[@]}" logs "$1" --container "$2" --tail=1000 "${@:3}" | jq -Rr '
    def scrub:
      gsub("(?i)(?<prefix>authorization[[:space:]\\\":=]+(?:bearer|basic)[[:space:]]+)[^[:space:]\\\",]+"; "\(.prefix)[REDACTED]") |
      gsub("(?i)(?<prefix>(?:password|passwd|secret|token|api_key|access_key)[[:space:]\\\":=]+)[^[:space:]\\\",;}]+"; "\(.prefix)[REDACTED]") |
      gsub("(?<scheme>https?://)[^/@[:space:]]+:[^/@[:space:]]+@"; "\(.scheme)[REDACTED]@") |
      gsub("(?:AKIA|ASIA)[A-Z0-9]{16}"; "[REDACTED]");
    (try fromjson catch null) as $entry |
    if ($entry | type) == "object" then
      $entry | walk(
        if type == "object" then with_entries(
          if (.key | test("(?i)(^|_)(password|passwd|secret|token|credentials|api_?key|access_?key)(_|$)|^(authorization|cookie|set-cookie)$"))
          then .value = "[REDACTED]" else . end)
        elif type == "string" then scrub else . end) | tojson
    else scrub end'
}

capture pods.json pods_snapshot
capture pod-readiness-restarts.json readiness_summary
capture pod-descriptions.txt pod_descriptions
capture events.json events_snapshot
capture deployments.json deployments_snapshot
while IFS= read -r deployment; do
  [[ -n "$deployment" ]] || continue
  capture "rollout-$deployment.txt" "${kube[@]}" rollout status "deployment/$deployment" --watch=false --timeout=10s
done < <(jq -r '.items[]?.name' "$output/deployments.json" 2>/dev/null || true)
capture helm-status.json helm_status
capture helm-history.json helm_history
capture services.json services_snapshot
while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  capture "endpoints-$service.json" endpoints_snapshot "$service"
done < <(jq -r '.items[]?.name' "$output/services.json" 2>/dev/null || true)

log_files=()
while IFS=$'\t' read -r pod container; do
  [[ -n "$pod" && -n "$container" ]] || continue
  file="logs-$pod-$container.log"
  capture "$file" container_logs "$pod" "$container"
  log_files+=("$output/$file")
done < <(jq -r '.items[] | .name as $pod | .containers[] |
  [$pod, .name] | @tsv' "$output/pods.json" 2>/dev/null || true)
# Find previous streams independently; containers may have no current log stream.
while IFS=$'\t' read -r pod container; do
  [[ -n "$pod" && -n "$container" ]] || continue
  file="logs-$pod-$container-previous.log"
  capture "$file" container_logs "$pod" "$container" --previous
  log_files+=("$output/$file")
done < <(jq -r '.items[] | .name as $pod | .container_statuses[] |
  select(.restartCount > 0) | [$pod, .name] | @tsv' "$output/pods.json" 2>/dev/null || true)
if [[ ${#log_files[@]} -gt 0 ]]; then
  capture http-summary.json "$script_dir/log-analyzer.sh" "${log_files[@]}"
else
  capture http-summary.json "$script_dir/log-analyzer.sh" /dev/null
fi

# Metrics are optional: metrics-server is intentionally absent from basic kind CI.
capture metrics-pods.txt "${kube[@]}" top pods -l "$selector" --containers
while IFS= read -r node; do
  [[ -n "$node" ]] || continue
  capture "node-$node.json" node_snapshot "$node"
  capture "metrics-node-$node.txt" "${kube[@]}" top node "$node"
done < <(jq -r '[.items[]?.node // empty] | unique[]' "$output/pods.json" 2>/dev/null || true)
printf 'Collection finished; see %s/collection-status.tsv for unavailable evidence.\n' "$output"
