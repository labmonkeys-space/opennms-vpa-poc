#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# floor.sh <component> <memory> [cpu] <dir>
# One floor rung: deploy with all VPAs Off, the component sized to the rung,
# verify the running limit, soak 10 minutes idle, record the outcome.
# With a cpu argument the CPU limit equals the request (CPU floor runs only).
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
comp="$1" mem="$2"
if [[ $# -eq 4 ]]; then cpu="$3"; dir="$4"; else cpu=""; dir="$3"; fi
pod="$comp-0"
soak="${FLOOR_SOAK:-600}"
case "$comp" in core) ready_timeout=1800 ;; *) ready_timeout=900 ;; esac

# Kubernetes may normalise a quantity (2048Mi -> 2Gi), so compare in bytes.
to_bytes() {
  local q="$1" n u
  n="${q%%[A-Za-z]*}"; u="${q#"$n"}"
  case "$u" in
    Ki) echo $(( n * 1024 )) ;;
    Mi) echo $(( n * 1024 * 1024 )) ;;
    Gi) echo $(( n * 1024 * 1024 * 1024 )) ;;
    k) echo $(( n * 1000 )) ;;
    M) echo $(( n * 1000 * 1000 )) ;;
    G) echo $(( n * 1000 * 1000 * 1000 )) ;;
    "") echo "$n" ;;
    *) echo "unsupported quantity $q" >&2; echo -1 ;;
  esac
}

sets=()
for c in postgresql kafka core minion; do sets+=(--set "vpa.components.$c.updateMode=Off"); done
sets+=(--set "$comp.resources.requests.memory=$mem" --set "$comp.resources.limits.memory=$mem")
if [[ -n "$cpu" ]]; then sets+=(--set "$comp.resources.requests.cpu=$cpu" --set "$comp.resources.limits.cpu=$cpu"); fi

mkdir -p "$dir"
start=$(date +%s)
helm upgrade --install poc "$campaign_root/charts/opennms-vpa" -n "$ns" --force-conflicts \
  -f "$campaign_root/campaign/values/nmt.yaml" "${sets[@]}" > "$dir/helm.txt"
kubectl -n "$ns" rollout status "statefulset/$comp" --timeout="${ready_timeout}s" > "$dir/rollout.txt" 2>&1 || true
ready=false
kubectl -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=10s >/dev/null 2>&1 && ready=true
ready_seconds=$(( $(date +%s) - start ))

limit="$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name==\"$comp\")].resources.limits.memory}")"
limit_verified=false
[[ -n "$limit" && "$(to_bytes "$limit")" == "$(to_bytes "$mem")" ]] && limit_verified=true

restarts_before="$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name==\"$comp\")].restartCount}")"
oom=false
if [[ "$ready" == true && "$limit_verified" == true ]]; then
  "$campaign_root/campaign/poller.sh" start "$dir" >/dev/null
  sleep "$soak"
  "$campaign_root/campaign/poller.sh" stop >/dev/null
  kubectl -n "$ns" top pod "$pod" --containers > "$dir/top.txt" 2>&1 || true
  if [[ "$comp" == core || "$comp" == minion ]]; then
    kubectl -n "$ns" exec "$pod" -c "$comp" -- sh -c \
      'pid=$(jcmd | awk "!/JCmd/{print \$1; exit}"); jcmd "$pid" VM.native_memory summary' > "$dir/nmt.txt" 2>&1 || true
  fi
fi
restarts_after="$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name==\"$comp\")].restartCount}")"
reason="$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name==\"$comp\")].lastState.terminated.reason}")"
[[ "$reason" == OOMKilled ]] && oom=true
restarts_during=$(( ${restarts_after:-0} - ${restarts_before:-0} ))
passed=false
[[ "$ready" == true && "$limit_verified" == true && "$oom" == false && "$restarts_during" -eq 0 ]] && passed=true

jq -n --arg comp "$comp" --arg mem "$mem" --arg cpu "$cpu" --argjson rs "$ready_seconds" \
  --argjson lv "$limit_verified" --argjson oom "$oom" --argjson rd "$restarts_during" --argjson ok "$passed" \
  --arg limit "$limit" \
  '{component:$comp, memory:$mem, cpu:$cpu, ready_seconds:$rs, running_limit:$limit,
    limit_verified:$lv, oom_killed:$oom, restarts_during_soak:$rd, passed:$ok}' > "$dir/result.json"
cat "$dir/result.json"
[[ "$passed" == true ]]
