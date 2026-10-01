#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# nmt.yaml must equal the chart's javaOpts plus the NMT flag, so a floor run
# measures the same JVM the chart ships.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
values="$root/charts/opennms-vpa/values.yaml"
overlay="$root/campaign/values/nmt.yaml"
fail=0
for block in core minion; do
  base="$(awk -v b="$block:" '$0==b{f=1;next} f&&/^[^ ]/{f=0} f&&/^  javaOpts:/{sub(/^  javaOpts: /,"");print;exit}' "$values")"
  got="$(awk -v b="$block:" '$0==b{f=1;next} f&&/^[^ ]/{f=0} f&&/^  javaOpts:/{sub(/^  javaOpts: /,"");print;exit}' "$overlay")"
  want="${base%\"} -XX:NativeMemoryTracking=summary\""
  if [[ -n "$base" && "$got" == "$want" ]]; then echo "ok   $block javaOpts = chart default + NMT"
  else echo "FAIL $block: got '$got' want '$want'"; fail=1; fi
done
exit "$fail"
