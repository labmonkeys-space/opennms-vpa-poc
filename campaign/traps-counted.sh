#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Print delivered-trap counters as one JSON object. Runs use the delta of
# linkdown_alarm_counter between two snapshots; the event count is reported
# too, because event rows can be removed by alarm auto-clean.
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
uei=uei.opennms.org/translator/traps/SNMP_Link_Down
sql="select (select count(*) from events where eventuei='$uei'),
            (select coalesce(sum(counter),0) from alarms where eventuei='$uei'),
            (select count(*) from alarms where eventuei='$uei')"
row="$(kubectl -n "$ns" exec postgresql-0 -c postgresql -- sh -c "psql -U \"\$POSTGRES_USER\" -d opennms -tA -F, -c \"$sql\"")"
IFS=, read -r events counter alarms <<<"$row"
udp="$(kubectl -n "$ns" exec minion-0 -c minion -- cat /proc/net/snmp | awk '/^Udp:/{n++; if(n==1){split($0,h)} else {for(i=2;i<=NF;i++) printf "%s\"%s\":%s", (i>2?",":""), h[i], $i}}')"
jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson e "$events" --argjson c "$counter" --argjson a "$alarms" \
  --argjson udp "{$udp}" \
  '{ts:$ts, linkdown_events:$e, linkdown_alarm_counter:$c, alarms:$a,
    minion_udp:{InDatagrams:$udp.InDatagrams, InErrors:$udp.InErrors, RcvbufErrors:$udp.RcvbufErrors}}'
