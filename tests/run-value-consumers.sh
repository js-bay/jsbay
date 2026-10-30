#!/bin/bash
# External C consumers use only installed public headers and a real archive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:?core archive required}"
OUTPUT="${2:?output directory required}"
mkdir -p "$OUTPUT"
# Zig Debug archives emit UBSan references; ReleaseFast typically does not, but
# linking -fsanitize=undefined is harmless and keeps Debug consumers green (see CI idle wake).
LIBS=(-lm -pthread -fsanitize=undefined)
if [ "$(uname -s)" = Darwin ]; then
    # JSC's module loader is Objective-C; match a real macOS C consumer.
    LIBS=(-lm -framework Foundation -framework JavaScriptCore -lobjc -fsanitize=undefined)
fi
(cd "$ROOT" && zig build tool -- check-c-abi "$ARCHIVE")
for consumer in value_contract_consumer value_edge_consumer jsc_bind_contract_consumer; do
    printf 'CONSUMER=%s
' "$consumer"
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$ROOT/include" "$ROOT/tests/$consumer.c" "$ARCHIVE" \
        "${LIBS[@]}" -o "$OUTPUT/$consumer"
    "$OUTPUT/$consumer"
done
for consumer in c_consumer bytecode_consumer; do
    printf 'CONSUMER=%s
' "$consumer"
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$ROOT/include" "$ROOT/tests/$consumer.c" "$ARCHIVE" \
        "${LIBS[@]}" -o "$OUTPUT/$consumer"
    "$OUTPUT/$consumer"
done
printf 'CONSUMER=native_sync_consumer\n'
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$ROOT/include" "$ROOT/tests/native_sync_consumer.c" "$ARCHIVE" \
    "${LIBS[@]}" -o "$OUTPUT/native_sync_consumer"
"$OUTPUT/native_sync_consumer"
