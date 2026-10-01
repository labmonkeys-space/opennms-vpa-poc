#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# ramp.sh <a|b> <dir>
# Phase 3 trap ramp: 10, 100, 500, 1000, 2000 traps/s at 200 sources.
# Each step floods in 300 s chunks until the core, minion and kafka VPA
# targets (cpu and memory) each moved less than 5 % across the last three
# 5-minute checks and all four pods stayed Ready without a restart, or 45 minutes
# passed. Both arms start from campaign/values/practical-floor.yaml. Arm A keeps
# memory static. Writes <dir>/steps.csv.
# Run campaign/reset-recommender.sh and campaign/manifest.sh first.
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
arm="${1:?usage: ramp.sh <a|b> <dir>}" dir="${2:?usage: ramp.sh <a|b> <dir>}"
[[ "$arm" == a || "$arm" == b ]] || die "arm must be a or b"
mkdir -p "$dir"
rates="${RAMP_RATES:-10 100 500 1000 2000}"
chunk="${RAMP_CHUNK:-300}"
max_step="${RAMP_MAX_STEP:-2700}"
drain="${RAMP_DRAIN:-120}"
first_wait="${RAMP_FIRST_WAIT:-600}"
sources=200
comps=(core minion kafka)
all_comps=(postgresql kafka core minion)
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$dir/ramp.log"; }

# Keys per source: one alarm per key (alarms_per_source equals the precheck's 20 keys) -> 100.
precheck="$(ls -d "$campaign_root"/runs/precheck/*/ 2>/dev/null | tail -1)"
aps="$(sed -n 's/^alarms_per_source: *//p' "${precheck}summary.md" 2>/dev/null | head -1)"
keys="${RAMP_KEYS:-}"
if [[ -z "$keys" ]]; then
  [[ -n "$aps" ]] || die "no alarms_per_source in precheck summary"
  if [[ "$aps" -ge 20 ]]; then keys=100; else keys=1; fi
fi

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
    *) echo 0 ;;
  esac
}
to_milli() {
  local q="$1"
  case "$q" in
    "") echo 0 ;;
    *m) echo "${q%m}" ;;
    *) awk -v v="$q" 'BEGIN{printf "%d", v*1000}' ;;
  esac
}

# macOS has no timeout(1). Run a command, kill it after <seconds>.
run_limited() {
  local secs="$1" pid wd rc=0; shift
  "$@" & pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null || true ) >/dev/null 2>&1 & wd=$!
  wait "$pid" || rc=$?
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  return "$rc"
}
kget() { kubectl -n "$ns" "$@"; }
running() { # <comp> <cpu|memory>
  kget get pod "$1-0" -o jsonpath="{.status.containerStatuses[?(@.name==\"$1\")].resources.requests.$2}" 2>/dev/null || true
}
template() {
  kget get sts "$1" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$1\")].resources.requests.$2}" 2>/dev/null || true
}
restarts_of() {
  local r
  r="$(kget get pod "$1-0" -o jsonpath="{.status.containerStatuses[?(@.name==\"$1\")].restartCount}" 2>/dev/null || true)"
  echo "${r:-0}"
}
vpa_target() { # <comp> <cpu|memory> -> raw quantity or empty
  kget get vpa "$1" -o jsonpath="{.status.recommendation.containerRecommendations[?(@.containerName==\"$1\")].target.$2}" 2>/dev/null || true
}
counters() { # retry: Minion or Postgres may be restarting
  local i out
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if out="$("$campaign_root/campaign/traps-counted.sh" 2>>"$dir/ramp.log")"; then echo "$out"; return 0; fi
    log "traps-counted failed (try $i), retrying in 30 s"; sleep 30
  done
  die "traps-counted kept failing"
}

"$campaign_root/campaign/poller.sh" start "$dir" | tee -a "$dir/ramp.log"
trap '"$campaign_root/campaign/poller.sh" stop >/dev/null' EXIT

echo "step_rate,started,ended,settled,sent,counted,lost,udp_rcvbuf_errors_delta,restarts_core,restarts_minion,restarts_kafka,restarts_postgresql,oom_core,oom_minion,oom_kafka,oom_postgresql" > "$dir/steps.csv"
echo "step_rate,chunks,flood_seconds,min_chunk_rate_ratio,generator_limited,settle_minutes" > "$dir/steps-detail.csv"

log "arm $arm keys $keys sources $sources dir ${dir#"$campaign_root/"}"
helm upgrade --install poc "$campaign_root/charts/opennms-vpa" -n "$ns" --force-conflicts --reset-values \
  -f "$campaign_root/campaign/values/practical-floor.yaml" -f "$campaign_root/campaign/values/arm-$arm.yaml" --wait --timeout 40m > "$dir/helm-initial.txt" 2>&1 \
  || die "initial helm upgrade failed, see $dir/helm-initial.txt"

# Clean pods: VPA resizes survive helm upgrade. Restart any pod whose running requests differ from the template.
: > "$dir/clean-pods.txt"
for c in "${all_comps[@]}"; do
  differs=false
  for res in cpu memory; do
    want="$(template "$c" "$res")"; have="$(running "$c" "$res")"
    if [[ "$res" == cpu ]]; then w="$(to_milli "$want")"; h="$(to_milli "$have")"; else w="$(to_bytes "$want")"; h="$(to_bytes "${have:-0}")"; fi
    echo "$c $res template=$want running=$have" >> "$dir/clean-pods.txt"
    [[ "$w" != "$h" ]] && differs=true
  done
  if [[ "$differs" == true ]]; then
    echo "$c-0 differs from its template; deleting for a clean start" >> "$dir/clean-pods.txt"
    kget delete pod "$c-0" --wait=true >> "$dir/clean-pods.txt" 2>&1
    kget wait --for=condition=Ready "pod/$c-0" --timeout=1800s >> "$dir/clean-pods.txt" 2>&1 || true
  fi
done
for c in "${all_comps[@]}"; do
  echo "$c final: cpu=$(running "$c" cpu) memory=$(running "$c" memory)" >> "$dir/clean-pods.txt"
done
cat "$dir/clean-pods.txt" >> "$dir/ramp.log"

log "waiting ${first_wait}s for the first VPA update"
sleep "$first_wait"

# 0 when core, minion and kafka cpu and memory targets each moved < 5 % over the last three samples.
settled_check() { # <samples-file>
  [[ "$(wc -l < "$1")" -ge 3 ]] || return 1
  tail -3 "$1" | awk '
    { for (i = 1; i <= NF; i++) { v = $i; if (v == "" || v == "x" || v + 0 <= 0) bad = 1;
        if (NR == 1 || v < mn[i]) mn[i] = v; if (NR == 1 || v > mx[i]) mx[i] = v } n = NF }
    END { if (bad) exit 1; for (i = 1; i <= n; i++) if ((mx[i] - mn[i]) / mn[i] >= 0.05) exit 1; exit 0 }'
}
sample_targets() {
  local line="" c
  for c in "${comps[@]}"; do
    local cpu mem
    cpu="$(vpa_target "$c" cpu)"; mem="$(vpa_target "$c" memory)"
    line+="$( [[ -n "$cpu" ]] && to_milli "$cpu" || echo x ) "
    # Arm A's cpu-only VPA computes no memory target, so memory is not part of its settle check.
    [[ "$arm" == a ]] || line+="$( [[ -n "$mem" ]] && to_bytes "$mem" || echo x ) "
  done
  echo "$line"
}

# "<all-ready 0|1> <restart total over the four pods>"
health_line() {
  local c ready=1 total=0 st
  for c in "${all_comps[@]}"; do
    st="$(kget get pod "$c-0" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$st" == True ]] || ready=0
    total=$(( total + $(restarts_of "$c") ))
  done
  echo "$ready $total"
}
# Settled needs the last three checks all Ready and no restart since the check before them.
health_ok() { # <health-file>: first line is the step baseline
  [[ "$(wc -l < "$1")" -ge 4 ]] || return 1
  tail -4 "$1" | awk 'NR==1{t=$2} NR>1{ if ($1!=1 || $2!=t) bad=1 } END{exit bad}'
}
# Flag a component whose last restart was an OOMKill and whose count rose in this step.
note_ooms() {
  local c reason now base
  for c in "${all_comps[@]}"; do
    reason="$(kget get pod "$c-0" -o jsonpath="{.status.containerStatuses[?(@.name==\"$c\")].lastState.terminated.reason}" 2>/dev/null || true)"
    now="$(restarts_of "$c")"
    case "$c" in core) base=$base_core ;; minion) base=$base_minion ;; kafka) base=$base_kafka ;; *) base=$base_pg ;; esac
    if [[ "$reason" == OOMKilled && "$now" -gt "$base" ]]; then eval "oom_$c=true"; fi
  done
}

for rate in $rates; do
  log "step $rate traps/s"
  snap1="$(counters)"
  base_core="$(restarts_of core)"; base_minion="$(restarts_of minion)"; base_kafka="$(restarts_of kafka)"; base_pg="$(restarts_of postgresql)"
  oom_core=false; oom_minion=false; oom_kafka=false; oom_postgresql=false
  health="$dir/health-$rate.txt"; echo "$(health_line)" > "$health"
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  samples="$dir/targets-$rate.txt"; : > "$samples"
  step_t0=$(date +%s); n=0; sent_total=0; flood_secs=0; settled=false; min_ratio=""; settle_min=""
  while :; do
    n=$(( n + 1 ))
    out="$dir/flood-$rate-$n.txt"
    c0=$(date +%s)
    run_limited $(( chunk + 120 )) "$campaign_root/campaign/flood.sh" "$rate" "$chunk" "$keys" "$sources" "$out" >/dev/null 2>>"$dir/ramp.log" \
      || log "flood chunk $rate-$n exited nonzero"
    flood_secs=$(( flood_secs + $(date +%s) - c0 ))
    s="$(sed -n 's/^sent \([0-9]*\) .*/\1/p' "$out" 2>/dev/null | tail -1)"
    r="$(sed -n 's/.* rate \([0-9.]*\)\/s .*/\1/p' "$out" 2>/dev/null | tail -1)"
    sent_total=$(( sent_total + ${s:-0} ))
    ratio="$(awk -v r="${r:-0}" -v q="$rate" 'BEGIN{printf "%.3f", r/q}')"
    if [[ -z "$min_ratio" ]] || awk -v a="$ratio" -v b="$min_ratio" 'BEGIN{exit !(a<b)}'; then min_ratio="$ratio"; fi
    sample_targets >> "$samples"
    health_line >> "$health"
    note_ooms
    if settled_check "$samples" && health_ok "$health"; then settled=true; settle_min=$(( ($(date +%s) - step_t0) / 60 )); break; fi
    [[ $(( $(date +%s) - step_t0 )) -ge $max_step ]] && break
  done
  log "step $rate: $n chunks, sent $sent_total, settled $settled"
  sleep "$drain"
  snap2="$(counters)"
  ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  counted="$(jq -n --argjson a "$snap1" --argjson b "$snap2" '$b.linkdown_alarm_counter - $a.linkdown_alarm_counter')"
  udp="$(jq -n --argjson a "$snap1" --argjson b "$snap2" '$b.minion_udp.RcvbufErrors - $a.minion_udp.RcvbufErrors')"
  if [[ "$udp" -lt 0 ]]; then
    log "Minion UDP counters reset during step $rate (pod restarted); using the post-restart value as a lower bound"
    udp="$(jq -n --argjson b "$snap2" '$b.minion_udp.RcvbufErrors')"
  fi
  note_ooms
  rc=$(( $(restarts_of core) - base_core ))
  rm_=$(( $(restarts_of minion) - base_minion ))
  rk=$(( $(restarts_of kafka) - base_kafka ))
  rp=$(( $(restarts_of postgresql) - base_pg ))
  echo "$rate,$started,$ended,$settled,$sent_total,$counted,$(( sent_total - counted )),$udp,$rc,$rm_,$rk,$rp,$oom_core,$oom_minion,$oom_kafka,$oom_postgresql" >> "$dir/steps.csv"
  glim=false; awk -v a="$min_ratio" 'BEGIN{exit !(a<0.95)}' && glim=true
  echo "$rate,$n,$flood_secs,$min_ratio,$glim,$settle_min" >> "$dir/steps-detail.csv"
done

kget get vpa -o json > "$dir/final-vpa.json"
kget get pods -o json | jq '[.items[] | {pod: .metadata.name, restarts: [.status.containerStatuses[] | {(.name): .restartCount}], requests: [.spec.containers[] | {(.name): .resources.requests}]}]' > "$dir/final-pods.json"
log "ramp arm $arm complete"
