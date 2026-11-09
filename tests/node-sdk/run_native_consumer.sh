#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
node_bin=${NODE_BIN:-node}
package_root=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-node-package.XXXXXX")
trap 'rm -rf "$package_root"' EXIT
archive=${JSBAY_LIBRARY:-}
if [[ -z $archive ]]; then
  build_dir=${JSBAY_NODE_BUILD_DIR:-"$package_root/core"}
  (cd "$root" && zig build -Dlibrary-only=true -Dbackend=quickjs_ng -Doptimize=ReleaseFast --prefix "$build_dir")
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
case "$(uname -s)" in
  Darwin) flags=(-dynamiclib -undefined dynamic_lookup -framework JavaScriptCore -framework Foundation) ;;
  Linux) flags=(-shared -fPIC -pthread) ;;
  *) echo "unsupported Node platform" >&2; exit 2 ;;
esac
"${CXX:-c++}" -std=c++17 -DJSBAY_NODE_TESTING=1 "${flags[@]}" -I"$root/include" -I"$root/sdk/node/include" -I"$node_include" -I"$(dirname "$node_include")" "$root/sdk/node/src/jsbay_node.cpp" "$archive" -o "$temporary_addon"
mv -f "$temporary_addon" "$addon"
JSBAY_NODE_ADDON="$addon" "$node_bin" "$root/tests/node-sdk/native_consumer.cjs"
JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/independent_consumer.cjs"
JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/fault_consumer.cjs"
for review_case in timer-microtask nested-thenable guest-then-getter explicit-undefined error-properties worker-finalizer pending-engine-gc sparse-array timer-close-observer conversion-rejects conversion-observer-rejects conversion-closes-engine worker-pending-natural-exit sync-host-throw argument-budget constructor-failure; do
  JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/review_consumer.cjs" "$review_case"
done
for review_case in cleanup-pending completion-reasons shared-handler-error synchronous-throw-completions call-host-failure; do
  JSBAY_NODE_ADDON="$addon" "$node_bin" --expose-gc "$root/tests/node-sdk/review_consumer.cjs" "$review_case"
done
JSBAY_NODE_ADDON="$addon" "$node_bin" "$root/tests/node-sdk/conversion_fault_consumer.cjs"
embed_addon="$output_dir/jsbay_node_embed.node"
"${CXX:-c++}" -std=c++17 -DJSBAY_NODE_EMBEDDED=1 "${flags[@]}" -I"$root/include" -I"$root/sdk/node/include" -I"$node_include" -I"$(dirname "$node_include")" "$root/sdk/node/src/jsbay_node.cpp" "$root/tests/node-sdk/embed_consumer.cc" "$archive" -o "$embed_addon"
JSBAY_NODE_EMBED_ADDON="$embed_addon" "$node_bin" "$root/tests/node-sdk/embed_consumer.cjs"
mkdir -p "$package_root/node_modules/@js-bay"
ln -s "$root/sdk/node" "$package_root/node_modules/@js-bay/node"
JSBAY_NODE_ADDON="$addon" JSBAY_NODE_PACKAGE_ROOT="$package_root/package.mjs" "$node_bin" "$root/tests/node-sdk/package_consumer.mjs"
if [[ -n ${TSC:-} ]]; then
  "$node_bin" "$TSC" --target ES2020 --module commonjs --strict --noEmit "$root/tests/node-sdk/declaration_consumer.ts"
  cp "$root/tests/node-sdk/package_type_consumer.cts" "$root/tests/node-sdk/package_esm_import.mts" "$package_root/"
  "$node_bin" "$TSC" --target ES2020 --module node16 --moduleResolution node16 --strict --noEmit "$package_root/package_type_consumer.cts"
  if "$node_bin" "$TSC" --target ES2020 --module node16 --moduleResolution node16 --strict --noEmit "$package_root/package_esm_import.mts" > "$package_root/esm-types.log" 2>&1; then
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
fi

cmake_bin=${CMAKE:-cmake}
"$cmake_bin" --version
cmake_output="$package_root/cmake"
"$cmake_bin" -S "$root/sdk/node" -B "$cmake_output" -DCMAKE_BUILD_TYPE=Release -DJSBAY_LIBRARY="$archive" -DNODE_INCLUDE="$node_include"
"$cmake_bin" --build "$cmake_output" --config Release
cmake_addon="$cmake_output/jsbay_node.node"
test -s "$cmake_addon"
JSBAY_NODE_ADDON="$cmake_addon" "$node_bin" "$root/tests/node-sdk/native_consumer.cjs"
JSBAY_NODE_ADDON="$cmake_addon" "$node_bin" --expose-gc "$root/tests/node-sdk/independent_consumer.cjs"
for review_case in timer-microtask nested-thenable guest-then-getter explicit-undefined error-properties worker-finalizer pending-engine-gc sparse-array timer-close-observer conversion-rejects conversion-observer-rejects conversion-closes-engine worker-pending-natural-exit sync-host-throw argument-budget constructor-failure; do
  JSBAY_NODE_ADDON="$cmake_addon" "$node_bin" --expose-gc "$root/tests/node-sdk/review_consumer.cjs" "$review_case"
done
JSBAY_NODE_ADDON="$cmake_addon" JSBAY_NODE_PACKAGE_ROOT="$package_root/package.mjs" "$node_bin" "$root/tests/node-sdk/package_consumer.mjs"
JSBAY_NODE_ADDON="$cmake_addon" "$node_bin" "$root/tests/node-sdk/production_consumer.cjs"
