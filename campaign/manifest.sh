#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# manifest.sh <dir> <phase> <arm> <reset-ts|none> [key=value]...
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
dir="$1" phase="$2" arm="$3" reset="$4"; shift 4
extra='{}'
for kv in "$@"; do extra="$(jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"$extra")"; done
rec="$(kubectl -n kube-system get deploy vpa-recommender -o json)"
jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sha "$(git -C "$campaign_root" rev-parse HEAD)" \
  --arg branch "$(git -C "$campaign_root" branch --show-current)" \
  --arg phase "$phase" --arg arm "$arm" --arg reset "$reset" \
  --argjson extra "$extra" \
  --argjson values "$(helm -n "$ns" get values poc -o json)" \
  --argjson images "$(kubectl -n "$ns" get pods -o json | jq '[.items[].spec.containers[] | {name, image}]')" \
  --arg k8s "$(kubectl version -o json | jq -r .serverVersion.gitVersion)" \
  --arg rec_image "$(jq -r '.spec.template.spec.containers[0].image' <<<"$rec")" \
  --argjson rec_args "$(jq '.spec.template.spec.containers[0].args // []' <<<"$rec")" \
  '{ts:$ts, git_sha:$sha, branch:$branch, phase:$phase, arm:$arm, recommender_reset:$reset,
    extra:$extra, kubernetes:$k8s, vpa_recommender:{image:$rec_image, args:$rec_args},
    images:$images, helm_values:$values}' > "$dir/manifest.json"
echo "manifest ${dir#"$campaign_root/"}/manifest.json"
