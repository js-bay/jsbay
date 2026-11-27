#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
target_script="$root/tests/dotnet-sdk/windows-target.sh"

expect_target() {
  local runner_arch=$1
  local expected=$2
  local actual
  actual=$(RUNNER_ARCH="$runner_arch" bash "$target_script")
  if [[ "$actual" != "$expected" ]]; then
    printf 'RUNNER_ARCH=%s: expected %s, got %s\n' "$runner_arch" "$expected" "$actual" >&2
    exit 1
  fi
}

expect_target X64 x86_64-windows-gnu
expect_target ARM64 aarch64-windows-gnu
rg -q 'windows-target\.sh' "$root/tests/dotnet-sdk/run.sh"
