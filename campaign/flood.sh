#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# flood.sh <rate> <duration> <keys> <sources> <out-file>
# Assumes the source pool is a /24 and sources <= 254.
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=/dev/null
source "$campaign_root/lab/lab.env"
rate="$1" duration="$2" keys="$3" sources="$4" out="$5"
lg="${LOADGEN_IP%/*}"
kh="$campaign_root/lab/.state/known_hosts"
base="${SOURCE_SUBNET%/*}"; base="${base%.*}"
src_args=""
for i in $(seq 1 "$sources"); do src_args+=" --source $base.$i"; done
scp -q -o UserKnownHostsFile="$kh" "$campaign_root/tools/trapflood.py" "lab@$lg:trapflood.py"
ssh -o UserKnownHostsFile="$kh" "lab@$lg" \
  "python3 trapflood.py --dest ${K8S_IP%/*}:30162 --rate $rate --duration $duration --keys $keys$src_args" | tee "$out"
