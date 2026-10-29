#!/usr/bin/env bash
# Extreme host process-isolation: one full publish-safe run.sh, then many harness
# iterations + sequential/parallel abort storms. Fault-injection OFF for publish check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOOPS="${EXTREME_HOST_LOOPS:-20}"
STORM_N="${EXTREME_STORM_N:-32}"
STORM_PAR_N="${EXTREME_STORM_PARALLEL_N:-24}"
OUT="${PROCESS_ISOLATION_OUT:-${TMPDIR:-/tmp}/jsbay-process-isolation-extreme}"
BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

LIBS=(-lm -pthread)
if [ "$(uname -s)" = Darwin ]; then
  LIBS=(-lm -framework Foundation -framework JavaScriptCore -lobjc)
fi

echo "== 1) full run.sh (publish-safe no-fault + baseline isolation) =="
PROCESS_ISOLATION_OUT="$OUT/baseline" bash "$ROOT/tests/process-isolation/run.sh" \
  || fail "baseline-run.sh"
pass "host-baseline-process-isolation"

echo "== 2) rebuild fault harness once, loop default parent $LOOPS times =="
rm -rf "$OUT/storm"
mkdir -p "$OUT/storm/fault" "$OUT/storm/bin"
(cd "$ROOT" && zig build -Dbackend="$BACKEND" -Doptimize=ReleaseFast -Dlibrary-only=true \
  -Dfault-injection=true --prefix "$OUT/storm/fault")
FAULT_A="$OUT/storm/fault/lib/libjsbay.a"
test -f "$FAULT_A"
# Publish archive from baseline must still lack symbol.
DEFAULT_A="$OUT/baseline/default/lib/libjsbay.a"
if [ -f "$DEFAULT_A" ] && nm "$DEFAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  fail "baseline default archive gained fault symbol"
fi
pass "baseline-default-still-no-fault-symbol"

"${CC:-cc}" -std=c11 -Wall -Wextra -Werror \
  -I"$ROOT/include" -I"$ROOT/tests/process-isolation" \
  "$ROOT/tests/process-isolation/harness.c" "$FAULT_A" \
  "${LIBS[@]}" -o "$OUT/storm/bin/process_isolation_harness"

for i in $(seq 1 "$LOOPS"); do
  set +e
  OUT_I="$("$OUT/storm/bin/process_isolation_harness" 2>&1)"
  RC_I=$?
  set -e
  if [ "$RC_I" -ne 0 ] || ! printf '%s' "$OUT_I" | grep -q 'PASS: process-isolation harness complete'; then
    printf '%s\n' "$OUT_I"
    fail "host-harness-loop-$i exit=$RC_I"
  fi
  echo "PASS: host-harness-loop-$i"
done
pass "host-isolation-loops-$LOOPS"

echo "== 3) storm sequential n=$STORM_N =="
set +e
SEQ_OUT="$("$OUT/storm/bin/process_isolation_harness" --storm "$STORM_N" 2>&1)"
SEQ_RC=$?
set -e
printf '%s\n' "$SEQ_OUT"
echo "storm_seq_exit=$SEQ_RC"
[ "$SEQ_RC" -eq 0 ] || fail "storm-sequential exit=$SEQ_RC"
printf '%s' "$SEQ_OUT" | grep -q "PASS: storm-sequential complete n=$STORM_N" \
  || fail "missing storm-sequential final PASS"
pass "host-storm-sequential-$STORM_N"

echo "== 4) storm parallel n=$STORM_PAR_N =="
set +e
PAR_OUT="$("$OUT/storm/bin/process_isolation_harness" --storm-parallel "$STORM_PAR_N" 2>&1)"
PAR_RC=$?
set -e
printf '%s\n' "$PAR_OUT"
echo "storm_par_exit=$PAR_RC"
[ "$PAR_RC" -eq 0 ] || fail "storm-parallel exit=$PAR_RC"
printf '%s' "$PAR_OUT" | grep -q "PASS: storm-parallel complete n=$STORM_PAR_N" \
  || fail "missing storm-parallel final PASS"
pass "host-storm-parallel-$STORM_PAR_N"

echo "PASS: extreme host process-isolation complete"
