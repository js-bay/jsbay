#!/usr/bin/env bash
# Apple public SDK benchmark runner. stdout is only five elapsed nanosecond values.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
runner=${1:?runner required}
backend=${2:-jsc}
case "$runner" in swift|objc) ;; *) echo "unsupported Apple runner: $runner" >&2; exit 64 ;; esac
case "$backend" in quickjs|quickjs_ng|jsc) ;; *) echo "unsupported backend: $backend" >&2; exit 64 ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-apple-interop.XXXXXX")
trap 'rm -rf "$work"' EXIT
prefix="$work/prefix"
zig build --prefix "$prefix" -Dlibrary-only=true -Dshared=false "-Dbackend=$backend" -Doptimize=ReleaseFast >&2
sdk=$(xcrun --sdk macosx --show-sdk-path)
target=arm64-apple-macos11.0
swift_flags=(-target "$target" -sdk "$sdk" -I"$root/include")
clang_flags=(-target "$target" -isysroot "$sdk" -I"$root/include")
backend_flags=(-DJSBAY_WITH_BYTECODE_CACHE)
if [ "$backend" = jsc ]; then backend_flags=(-DJSBAY_NO_BYTECODE_CACHE); fi
objc_fault_flag=
case "${JSBAY_INTEROP_FAULT:-}" in
  '') ;;
  empty_json) objc_fault_flag=-DJSBAY_INTEROP_FAULT_EMPTY_JSON ;;
  wrong_buffer) objc_fault_flag=-DJSBAY_INTEROP_FAULT_WRONG_BUFFER ;;
  *) echo "unsupported Objective-C interop fault: ${JSBAY_INTEROP_FAULT}" >&2; exit 64 ;;
esac

if [ "$runner" = swift ]; then
  xcrun --sdk macosx swiftc "${swift_flags[@]}" -swift-version 5 -emit-library -static -emit-module \
    -module-name JsBaySDK "$root/sdk/apple/Sources/JsBaySDK/JsBaySDK.swift" \
    -emit-module-path "$work/JsBaySDK.swiftmodule" -o "$work/libJsBaySDK.a" >&2
  xcrun --sdk macosx swiftc "${swift_flags[@]}" -swift-version 5 -I"$work" "${backend_flags[@]}" \
    "$root/bench/interop/apple/SwiftInteropBench.swift" "$work/libJsBaySDK.a" "$prefix/lib/libjsbay.a" \
    -framework JavaScriptCore -Xlinker -lm -o "$work/swift-interop" >&2
  "$work/swift-interop"
else
  xcrun --sdk macosx clang "${clang_flags[@]}" -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -I"$root/sdk/apple/Sources/JsBayObjC/include" "${backend_flags[@]}" ${objc_fault_flag:+"$objc_fault_flag"} \
    "$root/sdk/apple/Sources/JsBayObjC/JSBay.m" "$root/bench/interop/apple/ObjectiveCInteropBench.m" \
    "$prefix/lib/libjsbay.a" -framework Foundation -framework JavaScriptCore -lm -o "$work/objc-interop" >&2
  "$work/objc-interop"
fi
