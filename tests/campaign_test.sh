#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Offline checks for the campaign scripts. Live behaviour is checked in Task 5 Step 4.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

for s in lib poller reset-recommender manifest traps-counted flood load-inventory floor ramp resize-cost; do
  check "campaign/$s.sh exists" "[[ -f '$root/campaign/$s.sh' ]]"
done

# Review Focus 4: a second poller start must refuse while the first is alive.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sleep 60 & live=$!
echo "$live" > "$tmp/poller.pid"
rc=0
err="$(CAMPAIGN_KUBECONFIG=/nonexistent POLLER_PID_FILE="$tmp/poller.pid" bash "$root/campaign/poller.sh" start "$tmp/run" 2>&1 >/dev/null)" || rc=$?
ok=false; [[ "$rc" -ne 0 && "$err" == *"already running"* ]] && ok=true
check "poller refuses to start twice and says why" "$ok"
# lib.sh ignores an inherited KUBECONFIG.
got="$(KUBECONFIG=/inherited CAMPAIGN_KUBECONFIG=/chosen bash -c 'source "$1"; echo "$KUBECONFIG"' _ "$root/campaign/lib.sh")"
ok=false; [[ "$got" == /chosen ]] && ok=true
check "lib.sh uses CAMPAIGN_KUBECONFIG, not an inherited KUBECONFIG" "$ok"
kill "$live"; wait "$live" 2>/dev/null || true

# Review Focus 3: floor.sh must verify the running limit before it soaks.
check "floor.sh checks the running memory limit" \
  "grep -q 'containerStatuses' '$root/campaign/floor.sh' && grep -q 'resources.limits.memory' '$root/campaign/floor.sh'"

# Review Focus 5: accounting reports both counters.
check "traps-counted reports events and alarm counter" \
  "grep -q linkdown_events '$root/campaign/traps-counted.sh' && grep -q linkdown_alarm_counter '$root/campaign/traps-counted.sh'"
exit "$fail"
