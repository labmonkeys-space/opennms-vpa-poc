#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Install CNI, storage, metrics-server and upstream VPA with in-place resize.
# Idempotent: re-running re-applies the same manifests and flags.
#
# VPA_INSTALL_HOST=user@host runs upstream hack/vpa-up.sh on that host over
# SSH instead of locally. Use it when the local openssl cannot generate the
# admission webhook certificates. The host needs git, openssl and a kubeconfig.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${LAB_ENV:-$here/../lab.env}"
export KUBECONFIG="${KUBECONFIG:-$here/../.state/kubeconfig}"
state="$here/../.state"

kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
kubectl wait --for=condition=Ready node --all --timeout=300s

kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kubeadm kubelets serve self-signed certificates.
kubectl -n kube-system get deploy metrics-server -o json \
  | jq '.spec.template.spec.containers[0].args |= ((. // []) - ["--kubelet-insecure-tls"] + ["--kubelet-insecure-tls"])' \
  | kubectl apply -f -
kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s

vpa_repo="https://github.com/kubernetes/autoscaler"
vpa_tag="vertical-pod-autoscaler-${VPA_VERSION}"
if [[ -n "${VPA_INSTALL_HOST:-}" ]]; then
  ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$state/known_hosts" "$VPA_INSTALL_HOST" \
    "set -e; [ -d autoscaler ] || git clone --depth 1 --branch '$vpa_tag' '$vpa_repo' autoscaler; cd autoscaler/vertical-pod-autoscaler && TAG='$VPA_VERSION' ./hack/vpa-up.sh"
else
  src="$state/autoscaler"
  if [[ ! -d "$src" ]]; then
    git clone --depth 1 --branch "$vpa_tag" "$vpa_repo" "$src"
  fi
  (cd "$src/vertical-pod-autoscaler" && TAG="$VPA_VERSION" .//vpa-up.sh)
fi

# add_args <deployment> <arg>...: append flags once, keeping the existing ones.
add_args() {
  local deploy="$1"; shift
  local json; json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  kubectl -n kube-system get deploy "$deploy" -o json \
    | jq --argjson a "$json" '.spec.template.spec.containers[0].args |= ((. // []) - $a + $a)' \
    | kubectl apply -f -
  kubectl -n kube-system rollout status "deploy/$deploy" --timeout=300s
}
add_args vpa-updater --feature-gates=InPlaceOrRecreate=true
add_args vpa-admission-controller --feature-gates=InPlaceOrRecreate=true
# Short history so a load step is reflected in hours instead of days.
add_args vpa-recommender \
  --memory-aggregation-interval=1h \
  --memory-aggregation-interval-count=8 \
  --memory-histogram-decay-half-life=1h \
  --cpu-histogram-decay-half-life=1h
