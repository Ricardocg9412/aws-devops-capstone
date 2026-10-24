#!/usr/bin/env bash
# Analyze newline-delimited request logs; ignore startup and non-request entries.
set -Eeuo pipefail
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 LOG_FILE [LOG_FILE ...] (use - for stdin)" >&2
  exit 2
fi
command -v jq >/dev/null || { echo "jq is required" >&2; exit 127; }
jq -Rn '
  def is_request:
    type == "object" and .message == "request_completed"
    and (.method | type == "string") and (.path | type == "string")
    and (.status_code | type == "number")
    and .status_code >= 100 and .status_code < 600
    and .status_code == (.status_code | floor);
  reduce inputs as $line (
    {lines: 0, total: 0, four: 0, five: 0, duration_sum: 0, duration_samples: 0, endpoints: {}};
    .lines += 1 |
    (try ($line | fromjson) catch null) as $entry |
    if ($entry | is_request) then
      .total += 1 |
      .four += (if $entry.status_code >= 400 and $entry.status_code < 500 then 1 else 0 end) |
      .five += (if $entry.status_code >= 500 then 1 else 0 end) |
      ($entry.method + " " + $entry.path) as $endpoint |
      .endpoints[$endpoint] = ((.endpoints[$endpoint] // 0) + 1) |
      if ($entry.duration_ms | type) == "number" and $entry.duration_ms >= 0 then
        .duration_sum += $entry.duration_ms | .duration_samples += 1
      else . end
    else . end
  ) |
  {
    total_requests: .total,
    http_4xx: .four,
    http_5xx: .five,
    most_frequent_endpoint: (.endpoints | to_entries | sort_by(-.value, .key) | first // null |
      if . == null then null else {endpoint: .key, count: .value} end),
    average_duration_ms: (if .duration_samples == 0 then null
      else (.duration_sum / .duration_samples * 1000 | round) / 1000 end),
    duration_samples: .duration_samples,
    ignored_log_lines: (.lines - .total)
  }
' "$@"
