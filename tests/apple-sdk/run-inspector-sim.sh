#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE="${1:?usage: run-inspector-sim.sh <ios-simulator-libjsbay.a>}"
SIMULATOR="${JSBAY_IOS_SIM_UDID:?set JSBAY_IOS_SIM_UDID to a booted simulator}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-inspector-sim.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
case "$(uname -m)" in
    arm64|aarch64) TARGET=arm64-apple-ios14.0-simulator ;;
    x86_64) TARGET=x86_64-apple-ios13.0-simulator ;;
    *) echo 'Unsupported simulator host architecture.' >&2; exit 2 ;;
esac
xcrun --sdk iphonesimulator clang -std=c11 -Wall -Wextra -Werror \
    -target "$TARGET" -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -I "$ROOT/include" "$ROOT/examples/debug_owner_embed.c" "$ARCHIVE" \
    -framework Foundation -framework JavaScriptCore -lm -fsanitize=undefined \
    -o "$OUT/debug-owner"
codesign -s - --force "$OUT/debug-owner"
node "$ROOT/tests/inspector/ios_driver.cjs" "$SIMULATOR" "$OUT/debug-owner"
