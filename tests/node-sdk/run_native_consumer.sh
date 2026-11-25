#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
node_bin=${NODE_BIN:-node}
package_root=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-node-package.XXXXXX")
trap 'rm -rf "$package_root"' EXIT
archive=${JSBAY_LIBRARY:-}
if [[ -z $archive ]]; then
  build_dir=${JSBAY_NODE_BUILD_DIR:-"$package_root/core"}
  zig_args=(-Dlibrary-only=true -Dbackend=quickjs_ng -Doptimize=ReleaseFast --prefix "$build_dir")
  if [[ ${JSBAY_NODE_DISABLE_INSPECTOR_TRANSPORT:-0} == 1 ]]; then zig_args+=(-Dinspector-transport=false); fi
  (cd "$root" && zig build "${zig_args[@]}")
  archive="$build_dir/lib/libjsbay.a"
fi
if [[ -n ${NODE_INCLUDE:-} ]]; then
  node_include=$NODE_INCLUDE
else
  node_executable=$("$node_bin" -p 'process.execPath')
  node_prefix=$("$node_bin" -p 'process.config.variables.node_prefix || ""')
  for candidate in "$(dirname "$node_executable")/../include/node" "$node_prefix/include/node" /usr/include/node /usr/local/include/node /opt/homebrew/include/node; do
    if [[ -f "$candidate/node_api.h" ]]; then node_include=$candidate; break; fi
  done
fi
: "${node_include:?set NODE_INCLUDE to the directory containing node_api.h}"
output_dir=${JSBAY_NODE_OUTPUT_DIR:-"$package_root/output"}
mkdir -p "$output_dir"
addon="$output_dir/jsbay_node.node"
temporary_addon="$output_dir/jsbay_node.$$.node"
trap 'rm -f "$temporary_addon"; rm -rf "$package_root"' EXIT
run_stage() {
  local name=$1
  shift
  printf 'node SDK stage start: %s\n' "$name"
  "$@"
  printf 'node SDK stage passed: %s\n' "$name"
}
run_extended_contract_consumer() {
  local name=$1
  local addon=$2
  local -a public_env=(env JSBAY_NODE_ADDON="$addon")
  if [[ ${JSBAY_NODE_BACKEND:-} == jsc && ${JSBAY_NODE_PLATFORM:-} == darwin && ${JSBAY_NODE_ARCH:-} == arm64 ]]; then
    public_env+=(JSBAY_NODE_PUBLIC_ENTRY="$root/sdk/node/index.cjs")
  fi
  printf 'node SDK stage start: %s\n' "$name"
  local first_status=0
  if "${public_env[@]}" "$node_bin" "$root/tests/node-sdk/run-consumer-with-watchdog.mjs" 30000 "$node_bin" --expose-gc "$root/tests/node-sdk/extended_contract_consumer.cjs"; then
    printf 'node SDK stage passed: %s\n' "$name"
    return 0
  else
    first_status=$?
  fi
  return "$first_status"
}
run_jsc_arm64_public_entry_contracts() {
  if [[ ${JSBAY_NODE_BACKEND:-} != jsc || ${JSBAY_NODE_PLATFORM:-} != darwin || ${JSBAY_NODE_ARCH:-} != arm64 ]]; then return; fi
  local entry="$root/sdk/node/index.cjs"
  run_stage 'JSC core defaults polling before its first VM' env -u JSC_usePollingTraps JSBAY_NODE_ADDON="$addon" JSBAY_NODE_PUBLIC_ENTRY="$entry" "$node_bin" "$root/tests/node-sdk/jsc-polling-config-consumer.cjs" true
  run_stage 'JSC core preserves explicit polling opt-in' env JSC_usePollingTraps=1 JSBAY_NODE_ADDON="$addon" JSBAY_NODE_PUBLIC_ENTRY="$entry" "$node_bin" "$root/tests/node-sdk/jsc-polling-config-consumer.cjs" 1
  run_stage 'JSC core disables interrupt controls for explicit opt-out' env JSC_usePollingTraps=false JSBAY_NODE_ADDON="$addon" JSBAY_NODE_PUBLIC_ENTRY="$entry" "$node_bin" "$root/tests/node-sdk/jsc-polling-config-consumer.cjs" false
  run_stage 'JSC core rejects an invalid polling option' env JSC_usePollingTraps=maybe JSBAY_NODE_ADDON="$addon" JSBAY_NODE_PUBLIC_ENTRY="$entry" "$node_bin" "$root/tests/node-sdk/jsc-polling-config-consumer.cjs" maybe
  run_stage 'JSC Worker first addon load can interrupt execution' env -u JSC_usePollingTraps JSBAY_NODE_ADDON="$addon" JSBAY_NODE_PUBLIC_ENTRY="$entry" "$node_bin" "$root/tests/node-sdk/run-consumer-with-watchdog.mjs" 30000 "$node_bin" "$root/tests/node-sdk/jsc-worker-first-load-consumer.cjs"
}
case "$(uname -s)" in
  Darwin) flags=(-dynamiclib -undefined dynamic_lookup -framework JavaScriptCore -framework Foundation) ;;
  Linux) flags=(-shared -fPIC -pthread) ;;
  *) echo "unsupported Node platform" >&2; exit 2 ;;
esac
run_stage 'build test addon' "${CXX:-c++}" -std=c++17 -DJSBAY_NODE_TESTING=1 "${flags[@]}" -I"$root/include" -I"$root/sdk/node/include" -I"$node_include" -I"$(dirname "$node_include")" "$root/sdk/node/src/jsbay_node.cpp" "$archive" -o "$temporary_addon"
mv -f "$temporary_addon" "$addon"
run_stage 'test addon: native consumer' env JSBAY_NODE_ADDON="$addon" "$node_bin" "$root/tests/node-sdk/native_consumer.cjs"
run_stage 'test addon: independent consumer' env JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/independent_consumer.cjs"
run_stage 'test addon: fault consumer' env JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/fault_consumer.cjs"
for review_case in timer-microtask nested-thenable guest-then-getter explicit-undefined error-properties worker-finalizer worker-close-async-gc pending-engine-gc sparse-array timer-close-observer conversion-rejects conversion-observer-rejects conversion-closes-engine close-async-contract cache-option-reentrancy worker-pending-natural-exit sync-host-throw argument-budget constructor-failure; do
  run_stage "test addon: review case $review_case" env JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/review_consumer.cjs" "$review_case"
done
for review_case in cleanup-pending completion-reasons shared-handler-error synchronous-throw-completions call-host-failure; do
  run_stage "test addon: review case $review_case" env JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/review_consumer.cjs" "$review_case"
done
run_stage 'test addon: conversion fault consumer' env JSBAY_NODE_ADDON="$addon" "$node_bin" "$root/tests/node-sdk/conversion_fault_consumer.cjs"
run_jsc_arm64_public_entry_contracts
run_extended_contract_consumer 'test addon: extended contract consumer' "$addon"
run_stage 'test addon: value contract consumer' env JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/value_contract_consumer.cjs"
embed_addon="$output_dir/jsbay_node_embed.node"
run_stage 'build embedded addon' "${CXX:-c++}" -std=c++17 -DJSBAY_NODE_EMBEDDED=1 "${flags[@]}" -I"$root/include" -I"$root/sdk/node/include" -I"$node_include" -I"$(dirname "$node_include")" "$root/sdk/node/src/jsbay_node.cpp" "$root/tests/node-sdk/embed_consumer.cc" "$archive" -o "$embed_addon"
run_stage 'embedded addon consumer' env JSBAY_NODE_EMBED_ADDON="$embed_addon" "$node_bin" "$root/tests/node-sdk/embed_consumer.cjs"
production_addon=${JSBAY_NODE_RELEASE_ADDON:-}
if [[ -z $production_addon ]]; then
  cmake_bin=${CMAKE:-cmake}
  "$cmake_bin" --version
  cmake_output="$package_root/cmake"
  run_stage 'configure production addon' "$cmake_bin" -S "$root/sdk/node" -B "$cmake_output" -DCMAKE_BUILD_TYPE=Release -DJSBAY_LIBRARY="$archive" -DNODE_INCLUDE="$node_include"
  run_stage 'build production addon' "$cmake_bin" --build "$cmake_output" --config Release
  production_addon="$cmake_output/jsbay_node.node"
fi
test -s "$production_addon"
run_stage 'release addon: native consumer' env JSBAY_NODE_ADDON="$production_addon" "$node_bin" "$root/tests/node-sdk/native_consumer.cjs"
run_stage 'release addon: independent consumer' env JSBAY_NODE_ADDON="$production_addon" "$node_bin" --expose-gc "$root/tests/node-sdk/independent_consumer.cjs"
run_extended_contract_consumer 'release addon: extended contract consumer' "$production_addon"
run_stage 'release addon: value contract consumer' env JSBAY_NODE_ADDON="$production_addon" "$node_bin" --expose-gc "$root/tests/node-sdk/value_contract_consumer.cjs"
for review_case in timer-microtask nested-thenable guest-then-getter explicit-undefined error-properties worker-finalizer worker-close-async-gc pending-engine-gc sparse-array timer-close-observer conversion-rejects conversion-observer-rejects conversion-closes-engine close-async-contract cache-option-reentrancy worker-pending-natural-exit sync-host-throw argument-budget constructor-failure; do
  run_stage "release addon: review case $review_case" env JSBAY_NODE_ADDON="$production_addon" "$node_bin" --expose-gc "$root/tests/node-sdk/review_consumer.cjs" "$review_case"
done
run_stage 'release addon: production consumer' env JSBAY_NODE_ADDON="$production_addon" "$node_bin" "$root/tests/node-sdk/production_consumer.cjs"

if [[ -n ${TSC:-} ]]; then
  run_stage 'root package: declaration types' "$node_bin" "$TSC" --target ES2020 --module commonjs --strict --noEmit "$root/tests/node-sdk/declaration_consumer.ts"
  source_package="$package_root/npm-consumer/node_modules/@jsbay/node"
  mkdir -p "$source_package"
  cp "$root/sdk/node/"{package.json,index.cjs,index.d.ts} "$source_package/"
  cp "$root/tests/node-sdk/package_type_consumer.cts" "$root/tests/node-sdk/package_esm_import.mts" "$package_root/npm-consumer/"
  (
    cd "$package_root/npm-consumer"
    run_stage 'npm package: commonjs types' "$node_bin" "$TSC" --target ES2020 --module node16 --moduleResolution node16 --strict --noEmit package_type_consumer.cts
  )
  printf 'node SDK stage start: npm package: esm rejection contract\n'
  if (cd "$package_root/npm-consumer" && "$node_bin" "$TSC" --target ES2020 --module node16 --moduleResolution node16 --strict --noEmit package_esm_import.mts) > "$package_root/esm-types.log" 2>&1; then
    echo "expected ESM package import to be rejected" >&2
    exit 1
  fi
  if ! grep -F 'error TS2307:' "$package_root/esm-types.log"; then
    cat "$package_root/esm-types.log" >&2
    exit 1
  fi
  if grep -E 'error TS[0-9]+:' "$package_root/esm-types.log" | grep -v 'error TS2307:'; then
    cat "$package_root/esm-types.log" >&2
    exit 1
  fi
  printf 'node SDK stage passed: npm package: esm rejection contract\n'
fi
