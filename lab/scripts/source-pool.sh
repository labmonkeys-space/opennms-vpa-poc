#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Put the trap source pool on the load generator and route it back from the
# k8s node, so traps from pool addresses pass reverse-path filtering.
# Idempotent: addresses and the route use replace. Not persistent across reboots.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${LAB_ENV:-$here/../lab.env}"
kh="$here/../.state/known_hosts"
ssh_to() { ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" "lab@$1" "${@:2}"; }

lg="${LOADGEN_IP%/*}"
k8s="${K8S_IP%/*}"
prefix="${SOURCE_SUBNET#*/}"
base="${SOURCE_SUBNET%/*}"
base="${base%.*}"

ssh_to "$lg" "dev=\$(ip -o route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p');
  for i in \$(seq 1 $SOURCE_COUNT); do echo \"address replace $base.\$i/$prefix dev \$dev\"; done | sudo ip -batch -;
  echo loadgen: \$(ip -o -4 addr show dev \$dev | grep -c ' $base\.') pool addresses on \$dev"
ssh_to "$k8s" "sudo ip route replace $SOURCE_SUBNET via $lg && ip route show $SOURCE_SUBNET | sed 's/^/k8s node: /'"
