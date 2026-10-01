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
  printf 'K8S_VMID=4242\nLOADGEN_VMID=4343\n' > "$repo/lab/lab.env"
  printf '.check-public-terms\nlab/lab.env\n' > "$repo/.gitignore"
  printf '%s\n' "$content" > "$repo/notes.txt"
  (cd "$repo" && git init -q . && git config user.email t@example.com \
    && git config user.name t && git add -A && git commit -q -m case) >/dev/null
  bash "$repo/scripts/check-public.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: '$content' exited $got, want $want"; exit 1
  fi
}

# Hunk header "@@ -4242,7 +4242,7 @@" must not match, a content line must.
hunk_case() {
  local content="$1" want="$2" got=0 repo="$tmp/repo"
  rm -rf "$repo"; mkdir -p "$repo/scripts" "$repo/lab"
  cp "$src/scripts/check-public.sh" "$repo/scripts/"
  echo 'unrelated-term-xyz' > "$repo/.check-public-terms"
  printf 'K8S_VMID=4242\nLOADGEN_VMID=4343\n' > "$repo/lab/lab.env"
  printf '.check-public-terms\nlab/lab.env\n' > "$repo/.gitignore"
  awk "BEGIN{for(i=0;i<4300;i++)print \"x\"}" > "$repo/big.txt"
  (cd "$repo" && git init -q . && git config user.email t@example.com \
    && git config user.name t && git add -A && git commit -q -m one) >/dev/null
  sed "4245s/.*/${content:-y}/" "$repo/big.txt" > "$repo/big.new" && mv "$repo/big.new" "$repo/big.txt"
  (cd "$repo" && git commit -q -am two \
    && grep -q '^@@ -4242,7 +4242,7 @@' <(git log -p -1)) >/dev/null
  bash "$repo/scripts/check-public.sh" >/dev/null 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: hunk case '$content' exited $got, want $want"; exit 1
  fi
}
hunk_case '' 0
hunk_case 'id 4242' 1

run_case 'size 42425 and 14343' 0
run_case 'K8S_VMID=4242' 1
run_case 'id: 4343' 1
echo "check-public_test: ok"
