#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# poller.sh start <dir> | stop
# Samples pod usage, resources, restarts and VPA bounds every 15 s into CSV.
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
pid_file="${POLLER_PID_FILE:-$campaign_root/lab/.state/poller.pid}"
interval="${POLLER_INTERVAL:-15}"

sample() {
  local dir="$1" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local usage pods vpas
  usage="$(kubectl get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/$ns/pods" 2>/dev/null || echo '{"items":[]}')"
  pods="$(kubectl -n "$ns" get pods -o json)"
  vpas="$(kubectl -n "$ns" get vpa -o json)"
  jq -r --arg ts "$ts" --argjson u "$usage" '
    .items[] as $p | $p.spec.containers[] as $c |
    ([$u.items[] | select(.metadata.name == $p.metadata.name) | .containers[] | select(.name == $c.name) | .usage] | .[0] // {}) as $use |
    ($p.status.containerStatuses // [] | map(select(.name == $c.name)) | .[0]) as $st |
    [$ts, $p.metadata.name, $c.name, ($use.cpu // ""), ($use.memory // ""),
     ($st.resources.requests.cpu // $c.resources.requests.cpu // ""),
     ($st.resources.requests.memory // $c.resources.requests.memory // ""),
     ($st.resources.limits.cpu // $c.resources.limits.cpu // ""),
     ($st.resources.limits.memory // $c.resources.limits.memory // ""),
     ($st.restartCount // 0), ($st.lastState.terminated.reason // "")] | @csv' <<<"$pods" >> "$dir/pods.csv"
  jq -r --arg ts "$ts" '
    .items[] | . as $v | (.status.recommendation.containerRecommendations // [] | .[0]) as $r |
    [$ts, $v.metadata.name, ($r.target.cpu // ""), ($r.target.memory // ""),
     ($r.lowerBound.cpu // ""), ($r.lowerBound.memory // ""),
     ($r.upperBound.cpu // ""), ($r.upperBound.memory // "")] | @csv' <<<"$vpas" >> "$dir/vpa.csv"
}

case "${1:-}" in
  start)
    dir="${2:?usage: poller.sh start <dir>}"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      die "poller already running (pid $(cat "$pid_file"))"
    fi
    mkdir -p "$dir"
    echo "ts,pod,container,cpu_usage,mem_usage,req_cpu,req_mem,lim_cpu,lim_mem,restarts,last_reason" > "$dir/pods.csv"
    echo "ts,vpa,target_cpu,target_mem,lower_cpu,lower_mem,upper_cpu,upper_mem" > "$dir/vpa.csv"
    ( while true; do sample "$dir" || true; sleep "$interval"; done ) >/dev/null 2>&1 &
    echo $! > "$pid_file"
    echo "poller started pid $! -> ${dir#"$campaign_root/"}"
    ;;
  stop)
    if [[ -f "$pid_file" ]]; then kill "$(cat "$pid_file")" 2>/dev/null || true; rm -f "$pid_file"; fi
    echo "poller stopped"
    ;;
  *) die "usage: poller.sh start <dir> | stop" ;;
esac
