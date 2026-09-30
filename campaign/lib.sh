#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for campaign scripts. Source it; do not run it.
set -euo pipefail
campaign_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$campaign_root/lab/.state/kubeconfig}"
# shellcheck disable=SC2034  # used by scripts that source this file
ns=poc

die() { echo "error: $*" >&2; exit 1; }

run_dir() {
  local d
  d="$campaign_root/runs/$1/$(date -u +%Y%m%dT%H%M%SZ)${2:+-$2}"
  mkdir -p "$d"
  echo "$d"
}

with_core_pf() {
  kubectl -n poc port-forward svc/core 18980:8980 >/dev/null 2>&1 &
  CORE_PF=$!
  trap 'kill "$CORE_PF" 2>/dev/null || true' EXIT
  CORE_URL=http://127.0.0.1:18980/opennms
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null "$CORE_URL/login.jsp" && return 0
    sleep 2
  done
  die "Core port-forward did not come up"
}

core_rest() {
  local path="$1"; shift
  curl -sf -u admin:admin -H 'Accept: application/json' "$@" "$CORE_URL/rest/$path"
}
