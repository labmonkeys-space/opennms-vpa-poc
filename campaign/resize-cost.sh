#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# resize-cost.sh <inplace|helm|recreate> <core|minion|kafka> <dir>
# Phase 4: force one +512Mi memory increase on one component while 500 traps/s
# (200 sources, 100 keys) flow. Measures the time until the pod is Ready again
# with the new running limit, and the traps lost.
#   inplace   kubectl patch pod --subresource resize (requests and limits)
#   helm      helm upgrade with the component's memory raised, pod recreated
#   recreate  kubectl delete pod while the StatefulSet template carries the new size
# Each run: reset the recommender, deploy campaign/values/phase4-start.yaml (VPAs Off),
# clean pods, wait for Ready, wait for the alarm counter to be quiet, then measure.
# Afterwards the component goes back to its start size with the same overlay deploy.
# Flood: starts 60 s before the resize, stops 180 s after Ready, in 30 s chunks.
# lost = sent - alarm counter delta, taken once the counter is quiet.
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
mode="${1:?usage: resize-cost.sh <inplace|helm|recreate> <core|minion|kafka> <dir>}"
comp="${2:?usage}" dir="${3:?usage}"
case "$mode" in inplace|helm|recreate) ;; *) die "mode must be inplace, helm or recreate" ;; esac
case "$comp" in
  core) start_mi=4352; ready_timeout=1800 ;;
  minion) start_mi=1536; ready_timeout=900 ;;
  kafka) start_mi=768; ready_timeout=900 ;;
  *) die "component must be core, minion or kafka" ;;
esac
target_mi=$(( start_mi + 512 ))
pod="$comp-0"
rate=500 keys=100 sources=200 chunk=30
pre_flood="${RC_PRE_FLOOD:-60}" post_ready="${RC_POST_READY:-180}"
quiet_cap="${RC_QUIET_CAP:-1800}"
overlay="$campaign_root/campaign/values/phase4-start.yaml"
all_comps=(postgresql kafka core minion)
mkdir -p "$dir"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$dir/run.log"; }
kget() { kubectl -n "$ns" "$@"; }

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
  case "$1" in
    "") echo 0 ;;
    *m) echo "${1%m}" ;;
    *) awk -v v="$1" 'BEGIN{printf "%d", v*1000}' ;;
  esac
}
running() { kget get pod "$1-0" -o jsonpath="{.status.containerStatuses[?(@.name==\"$1\")].resources.requests.$2}" 2>/dev/null || true; }
template() { kget get sts "$1" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$1\")].resources.requests.$2}" 2>/dev/null || true; }
restarts_of() {
  local r
  r="$(kget get pod "$1-0" -o jsonpath="{.status.containerStatuses[?(@.name==\"$1\")].restartCount}" 2>/dev/null || true)"
  echo "${r:-0}"
}
started_of() { kget get pod "$1-0" -o jsonpath="{.status.containerStatuses[?(@.name==\"$1\")].state.running.startedAt}" 2>/dev/null || true; }
counters() {
  local i out
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if out="$("$campaign_root/campaign/traps-counted.sh" 2>>"$dir/run.log")"; then echo "$out"; return 0; fi
    log "traps-counted failed (try $i), retrying in 30 s"; sleep 30
  done
  die "traps-counted kept failing"
}

# Deploy the Phase 4 start sizes. A crash-looping pod from an earlier run can fail --wait, so retry.
deploy_start() { # <tag> [extra helm args]
  local tag="$1" try; shift
  for try in 1 2 3; do
    if helm upgrade --install poc "$campaign_root/charts/opennms-vpa" -n "$ns" --force-conflicts --reset-values \
      -f "$overlay" "$@" --wait --timeout 40m > "$dir/helm-$tag-$try.txt" 2>&1; then return 0; fi
    log "helm upgrade $tag failed (try $try), see helm-$tag-$try.txt"
  done
  return 1
}
# VPA resizes and earlier in-place patches survive a helm upgrade. Delete any pod whose running requests differ from its template.
clean_pods() { # <tag>
  local c res want have w h differs f="$dir/clean-pods-$1.txt"
  : > "$f"
  for c in "${all_comps[@]}"; do
    differs=false
    for res in cpu memory; do
      want="$(template "$c" "$res")"; have="$(running "$c" "$res")"
      if [[ "$res" == cpu ]]; then w="$(to_milli "$want")"; h="$(to_milli "$have")"; else w="$(to_bytes "$want")"; h="$(to_bytes "${have:-0}")"; fi
      echo "$c $res template=$want running=$have" >> "$f"
      [[ "$w" != "$h" ]] && differs=true
    done
    if [[ "$differs" == true ]]; then
      echo "$c-0 differs from its template; deleting" >> "$f"
      kget delete pod "$c-0" --wait=true >> "$f" 2>&1
    fi
  done
  for c in "${all_comps[@]}"; do
    kget wait --for=condition=Ready "pod/$c-0" --timeout=1800s >> "$f" 2>&1 || die "$c-0 not Ready after clean pods"
    echo "$c final: cpu=$(running "$c" cpu) memory=$(running "$c" memory)" >> "$f"
  done
  cat "$f" >> "$dir/run.log"
}

# Wait until linkdown_alarm_counter is unchanged across three 30 s checks, capped. Sets q_json, q_last_change (epoch), q_hit_cap.
q_json=""; q_last_change=0; q_hit_cap=false
wait_quiet() { # <cap-seconds>
  local cap="$1" quiet=0 prev="" cur waited=0
  q_hit_cap=false; q_last_change=$(date +%s)
  while :; do
    q_json="$(counters)"
    cur="$(jq -r .linkdown_alarm_counter <<<"$q_json")"
    if [[ "$cur" == "$prev" ]]; then quiet=$(( quiet + 1 )); else quiet=0; q_last_change=$(date +%s); fi
    prev="$cur"
    [[ "$quiet" -ge 3 ]] && break
    if [[ "$waited" -ge "$cap" ]]; then q_hit_cap=true; log "alarm counter not quiet after ${waited}s (cap)"; break; fi
    sleep 30; waited=$(( waited + 30 ))
  done
}

# "<Ready True|False> <running memory limit> <resize condition|-> <resize reason|->"
pod_state() {
  kget get pod "$pod" -o json 2>/dev/null | jq -r --arg c "$comp" '
    [ ([.status.conditions[]? | select(.type=="Ready") | .status] | first // "False"),
      ([.status.containerStatuses[]? | select(.name==$c) | .resources.limits.memory] | first // "-"),
      ([.status.conditions[]? | select(.type=="PodResizePending" or .type=="PodResizeInProgress") | .type] | first // "-"),
      ([.status.conditions[]? | select(.type=="PodResizePending") | .reason] | first // "-") ] | join(" ")' 2>/dev/null || echo "False - - -"
}

# ---- reset and deploy -------------------------------------------------------
log "run mode=$mode component=$comp start=${start_mi}Mi target=${target_mi}Mi dir=${dir#"$campaign_root/"}"
reset_out="$("$campaign_root/campaign/reset-recommender.sh")"; log "$reset_out"
reset_ts="${reset_out#recommender reset }"
deploy_start start || die "start deploy failed three times"
clean_pods start
"$campaign_root/campaign/manifest.sh" "$dir" phase4 "$mode" "$reset_ts" "mode=$mode" "component=$comp" nodes=20000 rate=500 start=phase4-start | tee -a "$dir/run.log"
wait_quiet 1800
log "pre-run counter quiet (hit cap $q_hit_cap)"
snap1="$q_json"
echo "$snap1" > "$dir/before.json"
id_before="$(kget get pod "$pod" -o jsonpath='{.metadata.uid} {.metadata.creationTimestamp}' 2>/dev/null || true)"
uid_before="${id_before%% *}"; created_before="${id_before#* }"
restarts_before=""
for c in "${all_comps[@]}"; do restarts_before+="$c=$(restarts_of "$c") "; done
started_before="$(started_of "$comp")"

# ---- flood in 30 s chunks ---------------------------------------------------
stop_at_file="$dir/flood-stop-at"; rm -f "$stop_at_file"
sent_file="$dir/flood-sent.txt"; : > "$sent_file"
flood_loop() {
  local n=0 dur stop_at now out s
  while :; do
    dur=$chunk
    if [[ -s "$stop_at_file" ]]; then
      stop_at="$(cat "$stop_at_file")"; now=$(date +%s)
      [[ "$now" -ge "$stop_at" ]] && break
      [[ $(( stop_at - now )) -lt "$dur" ]] && dur=$(( stop_at - now ))
    fi
    n=$(( n + 1 )); out="$dir/flood-$n.txt"
    "$campaign_root/campaign/flood.sh" "$rate" "$dur" "$keys" "$sources" "$out" >/dev/null 2>>"$dir/run.log" \
      || echo "flood chunk $n exited nonzero" >> "$dir/run.log"
    s="$(sed -n 's/^sent \([0-9]*\) .*/\1/p' "$out" 2>/dev/null | tail -1)"
    echo "$n ${s:-0} $dur" >> "$sent_file"
  done
}
"$campaign_root/campaign/poller.sh" start "$dir" >/dev/null || true
flood_t0=$(date +%s)
flood_loop & flood_pid=$!
cleanup() { kill "$flood_pid" 2>/dev/null || true; "$campaign_root/campaign/poller.sh" stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
log "flood started; resize in ${pre_flood}s"
sleep "$pre_flood"

# ---- the resize -------------------------------------------------------------
target="${target_mi}Mi"
failure=""
t0=$(date +%s)
log "resize $mode $comp -> $target"
case "$mode" in
  inplace)
    patch="{\"spec\":{\"containers\":[{\"name\":\"$comp\",\"resources\":{\"requests\":{\"memory\":\"$target\"},\"limits\":{\"memory\":\"$target\"}}}]}}"
    if ! kget patch pod "$pod" --subresource resize --type strategic -p "$patch" > "$dir/resize.txt" 2>&1; then
      failure="resize patch refused: $(tr '\n' ' ' < "$dir/resize.txt")"
    fi ;;
  helm)
    if ! helm upgrade --install poc "$campaign_root/charts/opennms-vpa" -n "$ns" --force-conflicts --reset-values \
      -f "$overlay" --set "$comp.resources.requests.memory=$target" --set "$comp.resources.limits.memory=$target" > "$dir/resize.txt" 2>&1; then
      failure="helm upgrade failed: $(tr '\n' ' ' < "$dir/resize.txt")"
    fi ;;
  recreate)
    # Delete first, then give the template the new size. The controller recreates the pod from the patched template.
    kget delete pod "$pod" --wait=false > "$dir/resize.txt" 2>&1 || failure="delete failed"
    patch="{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$comp\",\"resources\":{\"requests\":{\"memory\":\"$target\"},\"limits\":{\"memory\":\"$target\"}}}]}}}}"
    kget patch sts "$comp" --type strategic -p "$patch" >> "$dir/resize.txt" 2>&1 || failure="sts patch failed" ;;
esac

# ---- wait for Ready with the new limit --------------------------------------
ready_seconds=null
resize_reason="-"
if [[ -z "$failure" ]]; then
  want_bytes="$(to_bytes "$target")"
  while :; do
    read -r st lim cond reason <<<"$(pod_state)"
    [[ "$cond" != "-" ]] && resize_reason="$cond/$reason"
    if [[ "$reason" == Infeasible ]]; then failure="kubelet refused the resize: $cond/$reason"; break; fi
    if [[ "$st" == True && "$lim" != "-" && "$(to_bytes "$lim")" == "$want_bytes" && "$cond" == "-" ]]; then
      ready_seconds=$(( $(date +%s) - t0 )); break
    fi
    if [[ $(( $(date +%s) - t0 )) -ge "$ready_timeout" ]]; then failure="not Ready with ${target} within ${ready_timeout}s (state: $st $lim $cond $reason)"; break; fi
    sleep 2
  done
fi
if [[ -n "$failure" ]]; then log "FAILED: $failure"; stop_after=0; else log "Ready with $target after ${ready_seconds}s"; stop_after=$post_ready; fi
echo $(( $(date +%s) + stop_after )) > "$stop_at_file"
wait "$flood_pid" 2>/dev/null || true
flood_end=$(date +%s)
"$campaign_root/campaign/poller.sh" stop >/dev/null 2>&1 || true
trap - EXIT
log "flood stopped after $(( flood_end - flood_t0 )) s"

# ---- count once the counter is quiet ----------------------------------------
wait_quiet "$quiet_cap"
snap2="$q_json"
echo "$snap2" > "$dir/after.json"
id_after="$(kget get pod "$pod" -o jsonpath='{.metadata.uid} {.metadata.creationTimestamp}' 2>/dev/null || true)"
uid_after="${id_after%% *}"; created_after="${id_after#* }"
drain_seconds=$(( q_last_change - flood_end )); [[ "$drain_seconds" -lt 0 ]] && drain_seconds=0
sent="$(awk '{s+=$2} END{print s+0}' "$sent_file")"
flood_secs="$(awk '{s+=$3} END{print s+0}' "$sent_file")"
chunks_failed="$(grep -c 'exited nonzero' "$dir/run.log" || true)"
counted="$(jq -n --argjson a "$snap1" --argjson b "$snap2" '$b.linkdown_alarm_counter - $a.linkdown_alarm_counter')"
udp="$(jq -n --argjson a "$snap1" --argjson b "$snap2" '$b.minion_udp.RcvbufErrors - $a.minion_udp.RcvbufErrors')"
udp_lower_bound=false
if [[ "$udp" -lt 0 ]]; then
  udp="$(jq -n --argjson b "$snap2" '$b.minion_udp.RcvbufErrors')"; udp_lower_bound=true
  log "Minion UDP counters reset during the run; udp delta is the post-restart value (lower bound)"
fi
restarts_after=""
for c in "${all_comps[@]}"; do restarts_after+="$c=$(restarts_of "$c") "; done
oom=false
for c in "${all_comps[@]}"; do
  r="$(kget get pod "$c-0" -o jsonpath="{.status.containerStatuses[?(@.name==\"$c\")].lastState.terminated.reason}" 2>/dev/null || true)"
  [[ "$r" == OOMKilled ]] && oom=true
done
started_after="$(started_of "$comp")"
restarted=false; [[ "$started_before" != "$started_after" ]] && restarted=true
final_limit="$(kget get pod "$pod" -o jsonpath="{.status.containerStatuses[?(@.name==\"$comp\")].resources.limits.memory}" 2>/dev/null || true)"
passed=true; [[ -n "$failure" ]] && passed=false

jq -n --arg mode "$mode" --arg comp "$comp" --argjson rs "$ready_seconds" --argjson sent "$sent" --argjson counted "$counted" \
  --argjson udp "$udp" --argjson ulb "$udp_lower_bound" --argjson drain "$drain_seconds" --argjson cap "$q_hit_cap" \
  --argjson fs "$flood_secs" --argjson fw "$(( flood_end - flood_t0 ))" --argjson cf "${chunks_failed:-0}" \
  --argjson start "$start_mi" --argjson target "$target_mi" --arg limit "$final_limit" \
  --argjson restarted "$restarted" --argjson oom "$oom" --argjson ok "$passed" --arg failure "$failure" \
  --argjson base "$snap1" --argjson aft "$snap2" --arg ub "$uid_before" --arg cb "$created_before" --arg ua "$uid_after" --arg ca "$created_after" --arg rr "$resize_reason" --arg rb "$restarts_before" --arg ra "$restarts_after" \
  '{mode:$mode, component:$comp, ready_seconds:$rs, sent:$sent, counted:$counted, lost:($sent-$counted),
    udp_rcvbuf_errors_delta:$udp, udp_lower_bound:$ulb, drain_seconds:$drain, quiet_cap_hit:$cap,
    flood_seconds_sent:$fs, flood_wall_seconds:$fw, flood_chunks_failed:$cf,
    start_mi:$start, target_mi:$target, running_limit:$limit, container_restarted:$restarted,
    oom_killed_any:$oom, resize_condition:$rr, restarts_before:$rb, restarts_after:$ra,
    uid_before:$ub, created_before:$cb, uid_after:$ua, created_after:$ca,
    baseline:$base, after:$aft,
    passed:$ok, failure:$failure}' > "$dir/result.json"
cat "$dir/result.json"

# ---- restore the start sizes ------------------------------------------------
log "restoring phase4-start sizes"
deploy_start restore || die "restore deploy failed three times"
clean_pods restore
log "restored; all pods Ready"
[[ "$passed" == true ]]
