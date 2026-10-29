#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
node_bin=${NODE_BIN:-node}
tmp_root=${JSBAY_NAPI_HOST_DIR:-/tmp/jsbay-normalization/napi-host}
tsc=${TSC:-}
if [[ -z "$tsc" ]]; then
  for sdk in "${HARMONY_ETS_SDK:-}" \
    "${DEVECO_SDK_HOME:-}/default/openharmony/ets" \
    "${HARMONY_SDK_HOME:-}/sdk/packages/ohos-sdk/darwin/12/ets" \
    "${HARMONY_SDK_HOME:-}/sdk/packages/ohos-sdk/linux/12/ets"; do
    candidate="$sdk/build-tools/ets-loader/node_modules/typescript/lib/tsc.js"
    if [[ -f "$candidate" ]]; then tsc=$candidate; break; fi
  done
fi
: "${tsc:?set TSC to the SDK 12 TypeScript compiler or configure HARMONY_ETS_SDK}"
work="$tmp_root/facade"
test_source=${HARMONY_FACADE_TEST_SOURCE:-$repo_root/tests/harmony-sdk/facade_consumer.ts}

test -f "$tsc"
"$node_bin" "$tsc" --target ES2020 --module commonjs --strict --noEmit "$repo_root/tests/harmony-sdk/declaration_consumer.ts"
"$repo_root/tests/harmony-sdk/run_native_consumer.sh"
rm -rf "$work"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"
zig build --build-file "$repo_root/build.zig" tool -- harmony-facade "$repo_root/sdk/harmony/src/main/ets/JsBay.ets" "$work/JsBay.ts"
cp "$test_source" "$work/facade_consumer.ts"
"$node_bin" "$tsc" --target ES2020 --module commonjs --strict --skipLibCheck --outDir "$work/out" "$work/JsBay.ts" "$work/facade_consumer.ts"
JSBAY_HARMONY_NODE="$tmp_root/jsbay_harmony.node" "$node_bin" --expose-gc "$work/out/facade_consumer.js"
