#!/usr/bin/env bash
set -euo pipefail

toolchain_result=${1:?usage: check-harmony-required-gate.sh <toolchain-result> <har-result>}
har_result=${2:?usage: check-harmony-required-gate.sh <toolchain-result> <har-result>}

if [[ $toolchain_result != success || $har_result != success ]]; then
  printf 'Harmony HAR required check failed: toolchain=%s, har=%s. Both QuickJS HAR builds and the toolchain check must succeed; skipped and cancelled jobs do not count as success.\n' \
    "$toolchain_result" "$har_result" >&2
  if [[ $har_result == skipped ]]; then
    echo 'For a fork pull request, run the checked change on a reviewed branch with an approved Harmony runner before merging.' >&2
  fi
  exit 1
fi

echo 'Harmony HAR required check passed: toolchain and both backend builds succeeded.'
