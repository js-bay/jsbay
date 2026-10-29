#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
tmp_root=${JSBAY_NAPI_HOST_DIR:-/tmp/jsbay-normalization/napi-host}
node_bin=${NODE_BIN:-node}
: "${JSBAY_LIBRARY:?set JSBAY_LIBRARY to the host-platform libjsbay.a}"
archive=$JSBAY_LIBRARY
addon="$tmp_root/jsbay_harmony.node"
compiler=${CXX:-c++}
bridge_source=${HARMONY_BRIDGE_SOURCE:-$repo_root/sdk/harmony/src/main/cpp/jsbay_harmony.cpp}
mkdir -p "$tmp_root"

if [[ -n ${NODE_INCLUDE:-} ]]; then
  node_include=$NODE_INCLUDE
else
  node_prefix=$("$node_bin" -p 'process.config.variables.node_prefix || ""')
  for candidate in "$node_prefix/include/node" /usr/include/node /usr/local/include/node /opt/homebrew/include/node; do
    if [[ -f "$candidate/node_api.h" ]]; then node_include=$candidate; break; fi
  done
fi
: "${node_include:?set NODE_INCLUDE to the directory containing node_api.h}"

case "$(uname -s)" in
  Darwin) linker_flags=(-dynamiclib -undefined dynamic_lookup) ;;
  Linux) linker_flags=(-shared -fPIC) ;;
  *) echo "unsupported Node N-API host platform: $(uname -s)" >&2; exit 2 ;;
esac

"$compiler" -std=c++17 "${linker_flags[@]}" \
  -I"$repo_root/tests/harmony-sdk/node_napi/include" -I"$node_include" -I"$repo_root/include" \
  "$bridge_source" "$archive" -o "$addon"
if [[ ${HARMONY_SKIP_NATIVE_CONSUMER:-0} != 1 ]]; then
  JSBAY_HARMONY_NODE="$addon" "$node_bin" --expose-gc "$repo_root/tests/harmony-sdk/native_consumer.cjs"
fi
