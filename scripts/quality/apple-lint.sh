#!/bin/bash
# Compile public SDKs and external consumers, then run Clang's static analyzer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-apple-lint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET=arm64-apple-macos11.0
SWIFT_FLAGS=(-swift-version 5 -target "$TARGET" -sdk "$SDK" -warnings-as-errors -I"$ROOT/include")
CLANG_FLAGS=(-target "$TARGET" -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wnullability-completeness -Wdocumentation -I"$ROOT/include" -I"$ROOT/sdk/apple/Sources/JsBayObjC/include")
xcrun swiftc "${SWIFT_FLAGS[@]}" -emit-module -module-name JsBaySDK \
    "$ROOT/sdk/apple/Sources/JsBaySDK/JsBaySDK.swift" -emit-module-path "$WORK/JsBaySDK.swiftmodule"
xcrun swiftc "${SWIFT_FLAGS[@]}" -I"$WORK" -parse-as-library -typecheck "$ROOT/tests/apple-sdk/SwiftConsumer.swift"
xcrun swiftc "${SWIFT_FLAGS[@]}" -I"$WORK" -typecheck "$ROOT/tests/apple-sdk/spm-consumer/Sources/SwiftConsumer/main.swift"
for source in "$ROOT/sdk/apple/Package.swift" "$ROOT/tests/apple-sdk/spm-consumer/Package.swift.template"; do
    cp "$source" "$WORK/Package.swift"
    xcrun swiftc -frontend -parse "$WORK/Package.swift"
done
for source in "$ROOT/sdk/apple/Sources/JsBayObjC/JSBay.m" "$ROOT/tests/apple-sdk/ObjectiveCConsumer.m" "$ROOT/tests/apple-sdk/AllocationFailureConsumer.m"; do
    xcrun clang "${CLANG_FLAGS[@]}" -fsyntax-only "$source"
    xcrun clang "${CLANG_FLAGS[@]}" --analyze -Xanalyzer -analyzer-output=text -Xanalyzer -analyzer-werror "$source"
done
printf 'module JsBayObjC { header "%s" export * }\n' "$ROOT/sdk/apple/Sources/JsBayObjC/include/JSBayObjC.h" > "$WORK/module.modulemap"
xcrun clang "${CLANG_FLAGS[@]}" -fmodules -fmodules-cache-path="$WORK/modules" -I"$WORK" \
    -fsyntax-only "$ROOT/tests/apple-sdk/spm-consumer/Sources/ObjCConsumer/main.m"
bash "$ROOT/tests/apple-sdk/invalid-initializers.sh"
echo 'Apple lint: Swift SDK, manifests, Swift/Objective-C consumers, Clang analyzer passed (macOS 11 target)'
