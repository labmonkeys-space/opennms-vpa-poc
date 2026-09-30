#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Runs scripts/check-public.sh in throwaway repos to prove the VMID terms are
# digit-bounded: a whole VMID is blocked, a longer number containing it is not.
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# run_case <content> <expected exit code>
run_case() {
  local content="$1" want="$2" got=0
  local repo="$tmp/repo"
  rm -rf "$repo"; mkdir -p "$repo/scripts" "$repo/lab"
  cp "$src/scripts/check-public.sh" "$repo/scripts/"
  echo 'unrelated-term-xyz' > "$repo/.check-public-terms"
  printf 'K8S_VMID=9101\nLOADGEN_VMID=311\n' > "$repo/lab/lab.env"
  printf '.check-public-terms\nlab/lab.env\n' > "$repo/.gitignore"
  printf '%s\n' "$content" > "$repo/notes.txt"
  (cd "$repo" && git init -q . && git config user.email t@example.com \
    && git config user.name t && git add -A && git commit -q -m case) >/dev/null
  bash "$repo/scripts/check-public.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: '$content' exited $got, want $want"; exit 1
  fi
}

run_case 'size 2105 and 3110' 0
run_case 'K8S_VMID=9101' 1
run_case 'id: 311' 1
echo "check-public_test: ok"
