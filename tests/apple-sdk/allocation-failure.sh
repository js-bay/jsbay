#!/bin/bash
# Fault injection is confined to the SDK object used by this external consumer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE="${1:?core archive required}"
OUTPUT="${2:?output directory required}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
FLAGS=(-target arm64-apple-macos11.0 -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$ROOT/include" -I"$ROOT/sdk/apple/Sources/JsBayObjC/include")
mkdir -p "$OUTPUT"
xcrun clang "${FLAGS[@]}" -Dcalloc=JSBayTestCalloc -c "$ROOT/sdk/apple/Sources/JsBayObjC/JSBay.m" -o "$OUTPUT/objc-sdk-fault.o"
xcrun clang "${FLAGS[@]}" "$ROOT/tests/apple-sdk/AllocationFailureConsumer.m" "$OUTPUT/objc-sdk-fault.o" \
    "$ARCHIVE" -framework Foundation -framework JavaScriptCore -lm -o "$OUTPUT/allocation-failure-consumer"
ulimit -c 0
"$OUTPUT/allocation-failure-consumer"
