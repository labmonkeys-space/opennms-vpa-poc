#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Fails when tracked files, history or commit messages contain terms that must
# stay out of this public repository. Terms come from two gitignored sources:
# .check-public-terms (one extended regex per line) and the real lab hosts and
# addresses in lab/lab.env.
set -euo pipefail
cd "$(dirname "$0")/.."

terms=()
if [[ -f .check-public-terms ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] || terms+=("$line")
  done < .check-public-terms
fi
if [[ -f lab/lab.env ]]; then
  while IFS= read -r value; do
    [[ -n "$value" ]] && terms+=("${value//./\\.}")
  done < <(grep -E '^(PVE_HOST|K8S_IP|LOADGEN_IP|GATEWAY|DNS_SERVERS)=' lab/lab.env \
             | cut -d= -f2- | tr -s ' ,' '\n' | cut -d/ -f1)
fi
if [[ "${#terms[@]}" == 0 ]]; then
  echo "check-public: no terms configured. Create .check-public-terms first." >&2
  exit 2
fi
pattern="$(IFS='|'; echo "${terms[*]}")"

status=0
if git grep -n -i -E "$pattern"; then
  echo "check-public: forbidden content in tracked files" >&2; status=1
fi
if git log -p --all | grep -n -i -E "$pattern"; then
  echo "check-public: forbidden content in history" >&2; status=1
fi
if git log --all --format=%B | grep -n -i -E "$pattern"; then
  echo "check-public: forbidden content in commit messages" >&2; status=1
fi
[[ "$status" == 0 ]] && echo "check-public: clean"
exit "$status"
