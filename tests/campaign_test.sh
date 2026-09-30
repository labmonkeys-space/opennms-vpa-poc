#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Offline checks for the campaign scripts. Live behaviour is checked in Task 5 Step 4.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

for s in lib poller reset-recommender manifest traps-counted flood load-inventory floor; do
  check "campaign/$s.sh exists" "[[ -f '$root/campaign/$s.sh' ]]"
done

# Review Focus 4: a second poller start must refuse while the first is alive.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sleep 60 & live=$!
echo "$live" > "$tmp/poller.pid"
check "poller refuses to start twice" \
  "! POLLER_PID_FILE='$tmp/poller.pid' bash '$root/campaign/poller.sh' start '$tmp/run' >/dev/null 2>&1"
kill "$live"

# Review Focus 3: floor.sh must verify the running limit before it soaks.
check "floor.sh checks the running memory limit" \
  "grep -q 'containerStatuses' '$root/campaign/floor.sh' && grep -q 'resources.limits.memory' '$root/campaign/floor.sh'"

# Review Focus 5: accounting reports both counters.
check "traps-counted reports events and alarm counter" \
  "grep -q linkdown_events '$root/campaign/traps-counted.sh' && grep -q linkdown_alarm_counter '$root/campaign/traps-counted.sh'"
exit "$fail"
