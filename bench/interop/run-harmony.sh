#!/usr/bin/env bash
# Harmony benchmark runner: Node hosts the production N-API bridge only.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
runner=${1:?runner required}
backend=${2:-jsc}
case "$runner" in harmony_host_napi|harmony_typescript_check|harmony_arkts_check) ;; *) echo "unsupported Harmony runner: $runner" >&2; exit 64 ;; esac
case "$backend" in quickjs|quickjs_ng|jsc) ;; *) echo "unsupported backend: $backend" >&2; exit 64 ;; esac
node_bin=${NODE_BIN:-node}

if [ "$runner" = harmony_arkts_check ]; then
  # This path deliberately has no local SDK defaults. ArkTS must be checked by a caller-selected, internally consistent DevEco toolchain rather than a machine-specific SDK archive or a plain TypeScript compiler.
  : "${DEVECO_SDK_HOME:?set DEVECO_SDK_HOME to the DevEco SDK directory}"
  : "${OHPM:?set OHPM to the Harmony ohpm executable}"
  : "${HVIGORW:?set HVIGORW to the matching Hvigor entry point}"
  : "${JSBAY_HARMONY_ARCHIVE:?set JSBAY_HARMONY_ARCHIVE to an OpenHarmony libjsbay.a}"
  : "${NODE_PATH:?set NODE_PATH to the matching Hvigor module root}"
  test -d "$DEVECO_SDK_HOME"
  test -x "$OHPM"
  test -f "$HVIGORW"
  test -f "$JSBAY_HARMONY_ARCHIVE"

  work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-interop.XXXXXX")
  trap 'rm -rf "$work"' EXIT

  # The API 12 SDK cannot compile the fixture's normal API 20 project. Keep the product default untouched; build_har.sh creates this variant outside the repository. Call Hvigor through a transient no-daemon wrapper so the check owns no long-lived process.
  hvigor_wrapper="$work/hvigorw"
  # shellcheck disable=SC2016 # wrapper expands these values when it executes.
  printf '%s\n' '#!/bin/sh' \
    'if [ -x "$JSBAY_HVIGOR_ENTRY" ]; then exec "$JSBAY_HVIGOR_ENTRY" --no-daemon "$@"; fi' \
    'exec "$JSBAY_HVIGOR_NODE" "$JSBAY_HVIGOR_ENTRY" --no-daemon "$@"' > "$hvigor_wrapper"
  chmod +x "$hvigor_wrapper"
  (
    export JSBAY_HVIGOR_NODE="$node_bin" JSBAY_HVIGOR_ENTRY="$HVIGORW"
    export DEVECO_SDK_HOME JSBAY_LIBRARY="$JSBAY_HARMONY_ARCHIVE"
    export HVIGORW="$hvigor_wrapper" OHPM NODE_PATH
    export HARMONY_TARGET_SDK_VERSION="${HARMONY_TARGET_SDK_VERSION:-5.0.0(12)}"
    export HARMONY_EXTRA_ARKTS_FIXTURE="$root/bench/interop/harmony/ArkTSInteropBenchmark.ets"
    bash "$root/tests/harmony-sdk/build_har.sh"
  ) >&2
  har="$root/sdk/harmony/build/default/outputs/default/jsbay_harmony.har"
  test -f "$har"
  if tar -tzf "$har" | rg -F 'QualityArkTSInteropBenchmark.ets' >/dev/null; then
    echo "production HAR retained the temporary ArkTS benchmark fixture" >&2
    exit 1
  fi
  exit 0
fi

tsc=${TSC:-}
if [ -z "$tsc" ]; then
  for sdk in "${HARMONY_ETS_SDK:-}" "${DEVECO_SDK_HOME:-}/default/openharmony/ets" "${HARMONY_SDK_HOME:-}/sdk/packages/ohos-sdk/darwin/12/ets" "${HARMONY_SDK_HOME:-}/sdk/packages/ohos-sdk/linux/12/ets"; do
    candidate="$sdk/build-tools/ets-loader/node_modules/typescript/lib/tsc.js"
    if [ -f "$candidate" ]; then tsc=$candidate; break; fi
  done
fi
: "${tsc:?set TSC to the SDK TypeScript compiler or configure HARMONY_ETS_SDK}"
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-interop.XXXXXX")
trap 'rm -rf "$work"' EXIT

prepare_facade() {
  sed \
    -e "s|import native from 'libjsbay_harmony.so';|declare const require: (name: string) => any; declare const process: { env: { JSBAY_HARMONY_NODE?: string } }; const native: any = require(process.env.JSBAY_HARMONY_NODE as string);|" \
    -e "s|import util from '@ohos.util';|const util = { TextDecoder: { create: (encoding?: string) => ({ decodeToString: (input: Uint8Array, _options?: { stream?: boolean }) => new TextDecoder(encoding).decode(input) }) } };|" \
    "$root/sdk/harmony/src/main/ets/JsBay.ets" >"$work/JsBay.ts"
}

if [ "$runner" = harmony_typescript_check ]; then
  prepare_facade
  cp "$root/bench/interop/harmony/ArkTSInteropBenchmark.ets" "$work/ArkTSInteropBenchmark.ts"
  "$node_bin" "$tsc" --target ES2020 --module commonjs --strict --skipLibCheck --noEmit \
    "$work/JsBay.ts" "$work/ArkTSInteropBenchmark.ts" >&2
  exit 0
fi

prefix="$work/prefix"
zig build --prefix "$prefix" -Dlibrary-only=true -Dshared=false "-Dbackend=$backend" -Doptimize=ReleaseFast >&2
node_include=${NODE_INCLUDE:-}
if [ -z "$node_include" ]; then
  node_prefix=$("$node_bin" -p 'process.config.variables.node_prefix || ""')
  for candidate in "$node_prefix/include/node" /usr/include/node /usr/local/include/node /opt/homebrew/include/node; do
    if [ -f "$candidate/node_api.h" ]; then node_include=$candidate; break; fi
  done
fi
: "${node_include:?set NODE_INCLUDE to the directory containing node_api.h}"
cxx=${CXX:-c++}
case "$(uname -s)" in
  Darwin) link_flags=(-dynamiclib -undefined dynamic_lookup); if [ "$backend" = jsc ]; then link_flags+=(-framework JavaScriptCore -framework Foundation); fi ;;
  Linux) link_flags=(-shared -fPIC) ;;
  *) echo "unsupported Node N-API host platform: $(uname -s)" >&2; exit 2 ;;
esac
mkdir -p "$work/napi"
"$cxx" -std=c++17 "${link_flags[@]}" -I"$root/tests/harmony-sdk/node_napi/include" -I"$node_include" -I"$root/include" \
  "$root/sdk/harmony/src/main/cpp/jsbay_harmony.cpp" "$prefix/lib/libjsbay.a" -o "$work/napi/jsbay_harmony.node" >&2
prepare_facade
cp "$root/bench/interop/harmony/HostInteropBench.ts" "$work/HostInteropBench.ts"
"$node_bin" "$tsc" --target ES2020 --module commonjs --strict --skipLibCheck --outDir "$work/out" \
  "$work/JsBay.ts" "$work/HostInteropBench.ts" >&2
JSBAY_HARMONY_NODE="$work/napi/jsbay_harmony.node" "$node_bin" "$work/out/HostInteropBench.js"
