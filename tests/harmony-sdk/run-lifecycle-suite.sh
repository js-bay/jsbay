#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
output=${JSBAY_NAPI_HOST_DIR:-/tmp/jsbay-normalization/napi-host}
node_bin=${NODE_BIN:-node}
: "${JSBAY_LIBRARY:?set JSBAY_LIBRARY to the host-platform libjsbay.a}"
export JSBAY_HARMONY_NODE="$output/jsbay_harmony.node"
test -f "$JSBAY_HARMONY_NODE"

"$node_bin" --expose-gc "$root/tests/harmony-sdk/remediation_consumer.cjs"
"$node_bin" --expose-gc "$root/tests/harmony-sdk/submission_adversarial_consumer.cjs"
"$node_bin" "$root/tests/harmony-sdk/run-budget-matrix.cjs"
"$node_bin" --expose-gc "$root/tests/harmony-sdk/lifecycle_memory_consumer.cjs"
JSBAY_NAPI_HOST_DIR="$output/cleanup-failure" bash "$root/tests/harmony-sdk/run-cleanup-failure.sh"
