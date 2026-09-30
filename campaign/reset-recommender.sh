#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Clear VPA recommender history for the namespace so a run starts independent.
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
kubectl -n "$ns" delete verticalpodautoscalercheckpoints --all >/dev/null
kubectl -n kube-system rollout restart deploy/vpa-recommender >/dev/null
kubectl -n kube-system rollout status deploy/vpa-recommender --timeout=300s >/dev/null
echo "recommender reset $(date -u +%Y-%m-%dT%H:%M:%SZ)"
