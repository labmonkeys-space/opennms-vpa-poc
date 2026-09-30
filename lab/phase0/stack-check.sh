#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0 on the deployed stack:
#  1. Minion registers with Core.
#  2. A node is provisioned and an SNMPv2c trap from it becomes an alarm on that node.
#  3. Core CPU resizes in place without a restart.
#  4. A Minion memory resize restarts the container and the heap follows the new limit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab/phase0/lib.sh
source "$here/lib.sh"
# shellcheck source=/dev/null
source "${LAB_ENV:-$here/../lab.env}"
export KUBECONFIG="${KUBECONFIG:-$here/../.state/kubeconfig}"
ns=poc
k8s_ip="${K8S_IP%/*}"
loadgen_ip="${LOADGEN_IP%/*}"
ssh_lab=(ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$here/../.state/known_hosts" "lab@${loadgen_ip}")
out="$here/../../runs/phase0/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"

kubectl -n "$ns" port-forward svc/core 18980:8980 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
wait_for 60 "port-forward to Core" curl -sf -o /dev/null http://127.0.0.1:18980/opennms/login.jsp
rest() { curl -sf -u admin:admin -H 'Accept: application/json' "http://127.0.0.1:18980/opennms/rest/$1"; }

# 1. Minion registered and up.
minion_up() { rest minions | jq -e '.minion[]? | select(.location=="poc" and (.status|ascii_downcase)=="up")'; }
wait_for 600 "Minion UP at location poc" minion_up && ok=0 || ok=1
result "Minion registered with Core at location poc" "$ok"
[[ "$ok" == 0 ]] || rest minions | jq . >&2 || true

# 2. Provision the load generator as a node, then send it a linkDown trap.
curl -sf -u admin:admin -H 'Content-Type: application/xml' -X POST \
  http://127.0.0.1:18980/opennms/rest/requisitions --data @- <<XML
<model-import xmlns="http://xmlns.opennms.org/xsd/config/model-import" foreign-source="poc">
  <node foreign-id="loadgen" node-label="loadgen" location="poc">
    <interface ip-addr="${loadgen_ip}" snmp-primary="N"/>
  </node>
</model-import>
XML
curl -sf -u admin:admin -X PUT "http://127.0.0.1:18980/opennms/rest/requisitions/poc/import?rescanExisting=false"
node_present() { rest "nodes?label=loadgen" | jq -e '.totalCount == 1'; }
wait_for 300 "node loadgen provisioned" node_present && ok=0 || ok=1
result "node loadgen provisioned from requisition" "$ok"

# EventTranslator rewrites the donotpersist generic linkDown event into this alarm-bearing one.
uei=uei.opennms.org/translator/traps/SNMP_Link_Down
alarm_on_node() { rest "alarms?uei=${uei}" | jq -e '.alarm[]? | select(.nodeLabel=="loadgen")'; }
sent=0
for _ in 1 2 3; do
  # ssh joins its arguments, so the empty uptime argument needs quoting for the remote shell.
  "${ssh_lab[@]}" "snmptrap -v 2c -c public ${k8s_ip}:30162 '' .1.3.6.1.6.3.1.1.5.3 .1.3.6.1.2.1.2.2.1.1 i 1"
  sent=$(( sent + 1 ))
  if wait_for 60 "linkDown alarm on loadgen" alarm_on_node; then break; fi
done
alarm_on_node >/dev/null && ok=0 || ok=1
result "SNMPv2c trap became an alarm on node loadgen (source address preserved)" "$ok"
[[ "$ok" == 0 ]] || rest "alarms?uei=${uei}" | jq '.alarm[]? | {nodeLabel, ipAddress}' >&2 || true

# 3. Core CPU in place.
c_restarts() { pod_field "$ns" core-0 '{.status.containerStatuses[?(@.name=="core")].restartCount}'; }
core_r0="$(c_restarts)"
kubectl -n "$ns" patch vpa core --type merge -p '{"spec":{"updatePolicy":{"updateMode":"Off"}}}'
kubectl -n "$ns" patch pod core-0 --subresource resize \
  -p '{"spec":{"containers":[{"name":"core","resources":{"requests":{"cpu":"2"}}}]}}'
core_cpu() { [[ "$(pod_field "$ns" core-0 '{.status.containerStatuses[?(@.name=="core")].resources.requests.cpu}')" == 2 ]]; }
wait_for 120 "Core CPU resize applied" core_cpu && ok=0 || ok=1
[[ "$(c_restarts)" == "$core_r0" ]] || ok=1
result "Core CPU resized in place without restart" "$ok"

# 4. Minion memory resize: container restarts and -Xmx follows the limit.
xmx() {
  kubectl -n "$ns" exec minion-0 -c minion -- sh -c \
    'for p in /proc/[0-9]*; do tr "\0" " " < "$p/cmdline" 2>/dev/null; echo; done' \
    | grep -o -- '-Xmx[0-9]*m' | tail -1
}
m_restarts() { pod_field "$ns" minion-0 '{.status.containerStatuses[?(@.name=="minion")].restartCount}'; }
xmx_before="$(xmx)"
min_r0="$(m_restarts)"
kubectl -n "$ns" patch vpa minion --type merge -p '{"spec":{"updatePolicy":{"updateMode":"Off"}}}'
kubectl -n "$ns" patch pod minion-0 --subresource resize \
  -p '{"spec":{"containers":[{"name":"minion","resources":{"requests":{"memory":"2Gi"},"limits":{"memory":"2Gi"}}}]}}'
minion_restarted() { [[ "$(m_restarts)" == "$(( min_r0 + 1 ))" ]] && kubectl -n "$ns" wait --for=condition=Ready pod/minion-0 --timeout=5s; }
wait_for 600 "Minion restarted and ready" minion_restarted && ok=0 || ok=1
xmx_after="$(xmx || true)"
[[ "$xmx_after" == "-Xmx1228m" ]] || ok=1
result "Minion memory resize restarted the container and -Xmx followed (${xmx_before} -> ${xmx_after}, want -Xmx1228m)" "$ok"

jq -n \
  --arg core_image "$(pod_field "$ns" core-0 '{.spec.containers[?(@.name=="core")].image}')" \
  --arg minion_image "$(pod_field "$ns" minion-0 '{.spec.containers[?(@.name=="minion")].image}')" \
  --arg k8s "$(kubectl version -o json | jq -r .serverVersion.gitVersion)" \
  --arg xmx_before "$xmx_before" --arg xmx_after "$xmx_after" \
  --argjson traps_sent "$sent" --argjson failed "$FAILED" \
  '{phase: 0, kubernetes: $k8s, core_image: $core_image, minion_image: $minion_image,
    traps_sent: $traps_sent, minion_xmx_before: $xmx_before, minion_xmx_after: $xmx_after,
    passed: ($failed == 0)}' > "$out/results.json"
echo "wrote ${out#"$here/../../"}/results.json"
exit "$FAILED"
