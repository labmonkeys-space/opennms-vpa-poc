#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for campaign scripts. Source it; do not run it.
#
# These scripts are lab-bound. They expect namespace and release `poc`, the lab
# kubeconfig and lab/lab.env.
#
# Cluster selection: KUBECONFIG is set to lab/.state/kubeconfig. An inherited
# KUBECONFIG is ignored, so a script never touches whatever cluster the shell
# points at. Set CAMPAIGN_KUBECONFIG to use another kubeconfig.
#
# Wrong-cluster guard: unless CAMPAIGN_KUBECONFIG is set, the API server host of
# that kubeconfig must equal ${K8S_IP%/*} from lab/lab.env, or the script aborts.
# Setting CAMPAIGN_KUBECONFIG skips this check (used by offline tests).
set -euo pipefail
campaign_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # used by scripts that source this file
ns=poc

die() { echo "error: $*" >&2; exit 1; }

if [[ -n "${CAMPAIGN_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="$CAMPAIGN_KUBECONFIG"
else
  export KUBECONFIG="$campaign_root/lab/.state/kubeconfig"
  [[ -f "$campaign_root/lab/lab.env" ]] || die "lab/lab.env not found; cannot verify the cluster"
  lab_k8s="$(set -a; \
    # shellcheck source=/dev/null
    source "$campaign_root/lab/lab.env"; echo "${K8S_IP%/*}")"
  api_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  api_host="${api_server#*://}"; api_host="${api_host%%[:/]*}"
  [[ -n "$lab_k8s" && "$api_host" == "$lab_k8s" ]] \
    || die "kubeconfig API server '$api_host' is not the lab cluster '$lab_k8s'"
fi

run_dir() {
  local d
  d="$campaign_root/runs/$1/$(date -u +%Y%m%dT%H%M%SZ)${2:+-$2}"
  mkdir -p "$d"
  echo "$d"
}

with_core_pf() {
  kubectl -n "$ns" port-forward svc/core 18980:8980 >/dev/null 2>&1 &
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
