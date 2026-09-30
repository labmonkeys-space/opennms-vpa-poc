#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# make vendor must refuse an opennms-helm-charts checkout that lacks the VPA hooks.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/charts/core" "$tmp/charts/minion"
echo 'resources: {}' > "$tmp/charts/core/values.yaml"
echo 'resources: {}' > "$tmp/charts/minion/values.yaml"

if out="$(make -C "$root" --no-print-directory vendor HELM_CHARTS_DIR="$tmp" 2>&1)"; then
  echo "FAIL make vendor accepted a checkout without hooks"; exit 1
fi
if [[ "$out" != *"missing VPA hook"* ]]; then
  echo "FAIL unexpected message: $out"; exit 1
fi
echo "ok   make vendor rejects a checkout without hooks"
