#!/bin/bash
# Public Objective-C types must not inherit construction of invalid objects.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-invalid-initializers.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for class in JSBayEngine JSBayValue JSBaySyncCompletion JSBayCacheOptions; do
    for constructor in init new; do
        if [ "$constructor" = init ]; then expression="[[$class alloc] init]"; else expression="[$class new]"; fi
        printf '#import "JSBayObjC.h"\nvoid probe(void) { (void)%s; }\n' "$expression" > "$WORK/probe.m"
        if xcrun --sdk macosx clang -target arm64-apple-macos11.0 -isysroot "$SDK" \
            -fobjc-arc -fblocks -Wall -Wextra -Werror -fsyntax-only \
            -I"$ROOT/sdk/apple/Sources/JsBayObjC/include" "$WORK/probe.m" > "$WORK/diagnostics" 2>&1; then
            echo "$class $constructor unexpectedly compiled" >&2
            exit 1
        fi
        if ! grep -q "'$constructor' is unavailable" "$WORK/diagnostics"; then
            cat "$WORK/diagnostics" >&2
            exit 1
        fi
    done
done
echo 'Objective-C invalid initializers: 8 construction paths rejected'
