#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# load-inventory.sh <nodes> <sources> <dir>
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=/dev/null
source "$campaign_root/lab/lab.env"
nodes="$1" sources="$2" dir="$3"
python3 "$campaign_root/tools/requisition.py" --nodes "$nodes" --sources "$sources" \
  --source-subnet "$SOURCE_SUBNET" --out-dir "$dir/inventory"
with_core_pf
auth=(-u admin:admin -H 'Content-Type: application/xml')
curl -sf "${auth[@]}" -X POST "$CORE_URL/rest/foreignSources" --data @"$dir/inventory/foreign-source.xml"
curl -sf "${auth[@]}" -X POST "$CORE_URL/rest/requisitions" --data @"$dir/inventory/requisition.xml"
start=$(date +%s)
curl -sf -u admin:admin -X PUT "$CORE_URL/rest/requisitions/poc-scale/import?rescanExisting=false"
deadline=$(( start + 5400 ))
until [[ "$(core_rest 'nodes?limit=1&foreignSource=poc-scale' | jq '.totalCount')" -ge "$nodes" ]]; do
  (( $(date +%s) < deadline )) || die "import did not reach $nodes nodes in 90 min"
  sleep 20
done
jq -n --argjson n "$nodes" --argjson s "$sources" --argjson t "$(( $(date +%s) - start ))" \
  '{nodes:$n, sources:$s, import_seconds:$t}' > "$dir/inventory.json"
cat "$dir/inventory.json"
