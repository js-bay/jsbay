#!/bin/bash
# Format and lint every shipped Apple source and external consumer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-check}"
case "$MODE" in check|fix|self-test) ;; *) echo 'Usage: apple-style.sh [check|fix|self-test]' >&2; exit 2 ;; esac
SWIFT_FORMAT="${SWIFT_FORMAT:-$(xcrun --find swift-format)}"
EXPECTED_SWIFT_FORMAT=6.3.0
if [ "$("$SWIFT_FORMAT" --version)" != "$EXPECTED_SWIFT_FORMAT" ]; then
    echo "swift-format $EXPECTED_SWIFT_FORMAT is required; select the pinned Xcode toolchain or set SWIFT_FORMAT." >&2
    exit 2
fi
if [ "$MODE" = self-test ]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-swift-style.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
    printf 'func greet(){print("hello");print("world")}\n' > "$WORK/Probe.swift"
    if "$SWIFT_FORMAT" lint --strict --configuration "$ROOT/scripts/quality/apple-swift-format.json" "$WORK/Probe.swift" > "$WORK/expected-diagnostics" 2>&1; then
        echo 'Malformed Swift formatting unexpectedly passed lint.' >&2
        exit 1
    fi
    "$SWIFT_FORMAT" format --configuration "$ROOT/scripts/quality/apple-swift-format.json" --in-place "$WORK/Probe.swift"
    "$SWIFT_FORMAT" lint --strict --configuration "$ROOT/scripts/quality/apple-swift-format.json" "$WORK/Probe.swift"
    cp "$WORK/Probe.swift" "$WORK/Once.swift"
    "$SWIFT_FORMAT" format --configuration "$ROOT/scripts/quality/apple-swift-format.json" --in-place "$WORK/Probe.swift"
    cmp "$WORK/Once.swift" "$WORK/Probe.swift"
    echo 'Apple Swift style self-test: malformed source rejected, fix passed, second fix unchanged'
    exit 0
fi
SWIFT_FILES=()
while IFS= read -r -d '' source; do SWIFT_FILES+=("$source"); done < <(
    find "$ROOT/sdk/apple" "$ROOT/tests/apple-sdk" -type f \( -name '*.swift' -o -name '*.swift.template' \) -print0
)
if [ "${#SWIFT_FILES[@]}" -eq 0 ]; then echo 'No Apple Swift sources found.' >&2; exit 2; fi
if [ "$MODE" = fix ]; then
    "$SWIFT_FORMAT" format --configuration "$ROOT/scripts/quality/apple-swift-format.json" --in-place "${SWIFT_FILES[@]}"
fi
"$SWIFT_FORMAT" lint --strict --no-color-diagnostics --configuration "$ROOT/scripts/quality/apple-swift-format.json" "${SWIFT_FILES[@]}"
printf 'Apple Swift style: %s files checked with swift-format %s\n' "${#SWIFT_FILES[@]}" "$EXPECTED_SWIFT_FORMAT"
