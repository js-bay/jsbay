#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
output=${JSBAY_NAPI_HOST_DIR:-/tmp/jsbay-cleanup-failure}
JSBAY_NAPI_HOST_DIR="$output" \
  HARMONY_BRIDGE_SOURCE="$repo_root/tests/harmony-sdk/cleanup_failure_bridge.cpp" \
  HARMONY_SKIP_NATIVE_CONSUMER=1 \
  bash "$repo_root/tests/harmony-sdk/run_native_consumer.sh"
JSBAY_HARMONY_NODE="$output/jsbay_harmony.node" \
  "${NODE_BIN:-node}" "$repo_root/tests/harmony-sdk/cleanup_failure_consumer.cjs"
