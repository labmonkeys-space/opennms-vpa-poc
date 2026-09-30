#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0: in-place resize works on this cluster.
#  1. kubelet: CPU resize without restart, memory resize restarts the container, same pod.
#  2. VPA: InPlaceOrRecreate raises CPU on a busy single-replica Deployment without recreating the pod.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab/phase0/lib.sh
source "$here/lib.sh"
export KUBECONFIG="${KUBECONFIG:-$here/../.state/kubeconfig}"
ns=phase0

kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$ns" delete pod resize-probe --ignore-not-found --wait
kubectl -n "$ns" apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: resize-probe
spec:
  containers:
    - name: c
      image: busybox:1.37
      command: ["sleep", "86400"]
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {memory: 64Mi}
      resizePolicy:
        - {resourceName: cpu, restartPolicy: NotRequired}
        - {resourceName: memory, restartPolicy: RestartContainer}
YAML
kubectl -n "$ns" wait --for=condition=Ready pod/resize-probe --timeout=120s

uid="$(pod_field "$ns" resize-probe '{.metadata.uid}')"
restarts() { pod_field "$ns" resize-probe '{.status.containerStatuses[0].restartCount}'; }
r0="$(restarts)"

kubectl -n "$ns" patch pod resize-probe --subresource resize \
  -p '{"spec":{"containers":[{"name":"c","resources":{"requests":{"cpu":"200m"}}}]}}'
cpu_applied() { [[ "$(pod_field "$ns" resize-probe '{.status.containerStatuses[0].resources.requests.cpu}')" == 200m ]]; }
wait_for 120 "CPU resize applied" cpu_applied && ok=0 || ok=1
[[ "$(restarts)" == "$r0" ]] || ok=1
result "kubelet: CPU resize in place, restartCount unchanged" "$ok"

kubectl -n "$ns" patch pod resize-probe --subresource resize \
  -p '{"spec":{"containers":[{"name":"c","resources":{"requests":{"memory":"128Mi"},"limits":{"memory":"128Mi"}}}]}}'
mem_applied() { [[ "$(pod_field "$ns" resize-probe '{.status.containerStatuses[0].resources.limits.memory}')" == 128Mi ]]; }
wait_for 180 "memory resize applied" mem_applied && ok=0 || ok=1
[[ "$(restarts)" == "$(( r0 + 1 ))" ]] || ok=1
[[ "$(pod_field "$ns" resize-probe '{.metadata.uid}')" == "$uid" ]] || ok=1
result "kubelet: memory resize restarts the container once, same pod UID" "$ok"

kubectl -n "$ns" delete deploy burner --ignore-not-found --wait
kubectl -n "$ns" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: burner
spec:
  replicas: 1
  selector: {matchLabels: {app: burner}}
  template:
    metadata: {labels: {app: burner}}
    spec:
      containers:
        - name: c
          image: busybox:1.37
          command: ["sh", "-c", "while :; do :; done"]
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits: {memory: 32Mi}
          resizePolicy:
            - {resourceName: cpu, restartPolicy: NotRequired}
            - {resourceName: memory, restartPolicy: RestartContainer}
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: burner
spec:
  targetRef: {apiVersion: apps/v1, kind: Deployment, name: burner}
  updatePolicy: {updateMode: InPlaceOrRecreate, minReplicas: 1}
  resourcePolicy:
    containerPolicies:
      - containerName: c
        controlledResources: [cpu]
        minAllowed: {cpu: 50m}
        maxAllowed: {cpu: "1"}
YAML
kubectl -n "$ns" rollout status deploy/burner --timeout=120s
pod="$(kubectl -n "$ns" get pod -l app=burner -o jsonpath='{.items[0].metadata.name}')"
buid="$(pod_field "$ns" "$pod" '{.metadata.uid}')"
cpu_raised() {
  local m; m="$(pod_field "$ns" "$pod" '{.status.containerStatuses[0].resources.requests.cpu}')"
  [[ "$m" != 50m ]]
}
wait_for 1200 "VPA raised burner CPU" cpu_raised && ok=0 || ok=1
[[ "$(pod_field "$ns" "$pod" '{.metadata.uid}')" == "$buid" ]] || ok=1
result "VPA: InPlaceOrRecreate raised CPU on a single replica without recreating the pod" "$ok"
kubectl -n "$ns" get vpa burner -o jsonpath='{.status.recommendation.containerRecommendations[0].target}{"\n"}'

kubectl delete namespace "$ns" --wait=false
exit "$FAILED"
