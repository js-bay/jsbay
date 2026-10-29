#!/bin/bash
# External C consumers use only installed public headers and a real archive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:?core archive required}"
OUTPUT="${2:?output directory required}"
mkdir -p "$OUTPUT"
LIBS=(-lm -pthread)
if [ "$(uname -s)" = Darwin ]; then
    # JSC's module loader is Objective-C and ReleaseSafe archives carry the UBSan runtime references emitted by Zig. Link the same dependencies as a real macOS C consumer so every registered consumer executes.
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
