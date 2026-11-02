#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
: "${JSBAY_HARMONY_NODE:?set JSBAY_HARMONY_NODE to the compiled Node N-API bridge}"
node_bin=${NODE_BIN:-node}

"$node_bin" --expose-gc "$root/tests/harmony-sdk/lifecycle_memory_consumer.cjs"
