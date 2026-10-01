#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Clear VPA recommender history for the namespace so a run starts independent.
# Deleting checkpoints and restarting the recommender is not enough: the old
# .status.recommendation stays on the VPA objects until a new one is written.
# So this also deletes the VPA objects. The caller MUST run a helm upgrade
# (make deploy) afterwards to recreate them.
set -euo pipefail
# shellcheck source=campaign/lib.sh
source "$(dirname "$0")/lib.sh"
kubectl -n "$ns" delete verticalpodautoscalercheckpoints --all >/dev/null
kubectl -n "$ns" delete verticalpodautoscalers.autoscaling.k8s.io --all >/dev/null
kubectl -n kube-system rollout restart deploy/vpa-recommender >/dev/null
kubectl -n kube-system rollout status deploy/vpa-recommender --timeout=300s >/dev/null
echo "recommender reset $(date -u +%Y-%m-%dT%H:%M:%SZ)"
