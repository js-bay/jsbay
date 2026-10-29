#!/usr/bin/env bash
# Build libjsbay with/without -Dfault-injection and prove:
#   1) default ReleaseFast library-only has NO jsbay_test_trigger_native_fault symbol
#   2) fault-injection build exports it; intentional Zig abort kills only the child host
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${PROCESS_ISOLATION_OUT:-${TMPDIR:-/tmp}/jsbay-process-isolation}"
BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"
rm -rf "$OUT"
mkdir -p "$OUT/default" "$OUT/fault" "$OUT/bin"

LIBS=(-lm -pthread)
if [ "$(uname -s)" = Darwin ]; then
  LIBS=(-lm -framework Foundation -framework JavaScriptCore -lobjc)
fi

echo "== 1) default library-only ReleaseFast (no fault-injection) =="
(cd "$ROOT" && zig build -Dbackend="$BACKEND" -Doptimize=ReleaseFast -Dlibrary-only=true \
  --prefix "$OUT/default")
DEFAULT_A="$OUT/default/lib/libjsbay.a"
test -f "$DEFAULT_A"
if nm -g "$DEFAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  echo "FAIL: default build exports jsbay_test_trigger_native_fault"
  nm -g "$DEFAULT_A" | grep -E 'jsbay_test_trigger_native_fault' || true
  exit 1
fi
# Also scan archive members (some nm -g miss T on .a)
if nm "$DEFAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  echo "FAIL: default archive contains jsbay_test_trigger_native_fault"
  exit 1
fi
echo "PASS: default-build-no-fault-symbol"

echo "== 2) fault-injection library + process harness =="
(cd "$ROOT" && zig build -Dbackend="$BACKEND" -Doptimize=ReleaseFast -Dlibrary-only=true \
  -Dfault-injection=true --prefix "$OUT/fault")
FAULT_A="$OUT/fault/lib/libjsbay.a"
test -f "$FAULT_A"
if ! nm "$FAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  echo "FAIL: fault-injection build missing jsbay_test_trigger_native_fault"
  exit 1
fi
echo "PASS: fault-injection-build-has-symbol"
nm "$FAULT_A" | grep -E 'jsbay_test_trigger_native_fault' | head -5

"${CC:-cc}" -std=c11 -Wall -Wextra -Werror \
  -I"$ROOT/include" -I"$ROOT/tests/process-isolation" \
  "$ROOT/tests/process-isolation/harness.c" "$FAULT_A" \
  "${LIBS[@]}" -o "$OUT/bin/process_isolation_harness"

set +e
HARNESS_OUT="$("$OUT/bin/process_isolation_harness" 2>&1)"
HARNESS_RC=$?
set -e
printf '%s\n' "$HARNESS_OUT"
echo "harness_exit=$HARNESS_RC"

if [ "$HARNESS_RC" -ne 0 ]; then
  echo "FAIL: process-isolation harness exit=$HARNESS_RC"
  exit 1
fi
if ! printf '%s' "$HARNESS_OUT" | grep -q 'PASS: process-isolation harness complete'; then
  echo "FAIL: missing final PASS line"
  exit 1
fi
if ! printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-survives-abort-child'; then
  echo "FAIL: missing parent-survives-abort-child"
  exit 1
fi
if ! printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-survives-segfault-child'; then
  echo "FAIL: missing parent-survives-segfault-child"
  exit 1
fi

echo "PASS: process-isolation run.sh complete"
