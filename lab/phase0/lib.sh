#!/usr/bin/env bash
# shellcheck disable=SC2034  # FAILED is read by the scripts that source this file
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for Phase 0 checks.

# wait_for <timeout_s> <description> <command...>: poll every 5 s until the command succeeds.
wait_for() {
  local timeout="$1" what="$2"; shift 2
  local end=$(( $(date +%s) + timeout ))
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) > end )); then echo "timeout after ${timeout}s: $what" >&2; return 1; fi
    sleep 5
  done
}

# pod_field <ns> <pod> <jsonpath>
pod_field() { kubectl -n "$1" get pod "$2" -o jsonpath="$3"; }

# result <name> <0|1>: print and accumulate a check result in $FAILED.
FAILED=0
result() {
  if [[ "$2" == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi
}
