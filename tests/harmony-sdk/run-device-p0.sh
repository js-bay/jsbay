#!/usr/bin/env bash
# Install signed crash-isolation HAP on a connected Harmony device and wait for JSBAY_P0_HARMONY_PASS.
set -euo pipefail
HDC="${HDC:?set HDC to the hdc binary}"
TARGET="${HDC_SERIAL:-${1:?set HDC_SERIAL or pass device serial as \$1}}"
HAP="${HARMONY_P0_HAP:?set HARMONY_P0_HAP to a signed HAP path}"
BUNDLE=com.example.jsbay.eventwaiter
ABILITY=EntryAbility
LOG="${JSBAY_P0_HILOG:-/tmp/jsbay-p0-harmony-device-hilog.txt}"
test -x "$HDC"
test -f "$HAP"
"$HDC" -t "$TARGET" uninstall "$BUNDLE" >/dev/null 2>&1 || true
"$HDC" -t "$TARGET" install -r "$HAP"
"$HDC" -t "$TARGET" shell hilog -r >/dev/null 2>&1 || true
rm -f "$LOG"
"$HDC" -t "$TARGET" shell hilog >"$LOG" 2>&1 &
HILOG_PID=$!
sleep 1
"$HDC" -t "$TARGET" shell "aa start -a $ABILITY -b $BUNDLE"
DEADLINE=$((SECONDS + 90))
RESULT=TIMEOUT
while (( SECONDS < DEADLINE )); do
  if grep -q 'JSBAY_P0_HARMONY_PASS' "$LOG" 2>/dev/null; then RESULT=PASS; break; fi
  if grep -q 'JSBAY_P0_HARMONY_FAIL' "$LOG" 2>/dev/null; then RESULT=FAIL; break; fi
  sleep 1
done
kill "$HILOG_PID" 2>/dev/null || true
wait "$HILOG_PID" 2>/dev/null || true
echo "Result: $RESULT (log=$LOG)"
[[ "$RESULT" == PASS ]]
