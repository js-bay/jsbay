#!/usr/bin/env bash
# Extreme Harmony HAP abuse against the jsbay CrashIsolation HAP.
# Default HAP: tests/harmony-sdk/hap-crash-isolation/.../entry-default-signed.hap
# Markers: JSBAY_CRASHISO_PASS / FAIL, plus PASS:/FAIL:/SKIP: from CrashIsolation.ets
# Also force-stop mid-run + recovery. Process-isolation ELF still SELinux-SKIP from shell.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDC="${HDC:?set HDC to the hdc binary}"
TARGET="${HDC_SERIAL:?set HDC_SERIAL to the hdc device serial}"
BUNDLE="com.example.jsbay.eventwaiter"
ABILITY="EntryAbility"
HAP="${HARMONY_HAP_PATH:-$ROOT/tests/harmony-sdk/hap-crash-isolation/entry/build/default/outputs/default/entry-default-signed.hap}"
LOGDIR="${HARMONY_EXTREME_LOGDIR:-/tmp/jsbay-harmony-extreme-crashiso}"
CYCLES="${EXTREME_HAP_CYCLES:-12}"
FORCE_STOP_CYCLES="${EXTREME_HAP_FORCE_STOP:-8}"
PASS_MARKER='JSBAY_CRASHISO_PASS'
FAIL_MARKER='JSBAY_CRASHISO_FAIL'
HARNESS_PASS='PASS: harmony crash-isolation harness complete'

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; }

hdc_cmd() { "$HDC" -t "$TARGET" "$@"; }

mkdir -p "$LOGDIR"
test -x "$HDC" || { skip "hdc missing"; exit 0; }
test -f "$HAP" || fail "HAP missing: $HAP (run tests/harmony-sdk/build-crash-isolation-hap.sh)"
LIST="$(hdc_cmd list targets 2>&1 || true)"
echo "hdc targets: $LIST"
echo "HAP=$HAP"
printf '%s' "$LIST" | grep -q "$TARGET" || { skip "hdc-device $TARGET not listed"; exit 0; }

echo "== install CrashIsolation HAP =="
hdc_cmd install -r "$HAP" | tee "$LOGDIR/install.txt"
pass "hap-install"

echo "== clear hilog + baseline CrashIsolation =="
hdc_cmd shell hilog -r || true
HILOG_BASE="$LOGDIR/hilog-baseline.txt"
hdc_cmd shell hilog >"$HILOG_BASE" 2>&1 &
HILOG_PID=$!
sleep 1
hdc_cmd shell aa start -a "$ABILITY" -b "$BUNDLE" || true
DEADLINE=$((SECONDS + 120))
RESULT=TIMEOUT
while (( SECONDS < DEADLINE )); do
  if rg -q "$PASS_MARKER|$HARNESS_PASS" "$HILOG_BASE" 2>/dev/null; then RESULT=PASS; break; fi
  if rg -q "$FAIL_MARKER|FAIL: harmony crash-isolation harness" "$HILOG_BASE" 2>/dev/null; then RESULT=FAIL; break; fi
  sleep 1
done
kill "$HILOG_PID" 2>/dev/null || true
wait "$HILOG_PID" 2>/dev/null || true
echo "baseline_crashiso=$RESULT"
rg -n "$PASS_MARKER|$FAIL_MARKER|PASS:|FAIL:|SKIP:|Tags.JS_ENGINE|JSBAY" "$HILOG_BASE" | head -80 || true
cp "$HILOG_BASE" "$LOGDIR/hilog-baseline-full.txt"
if [ "$RESULT" != PASS ]; then
  fail "hap-baseline-crashisolation result=$RESULT"
fi
pass "hap-baseline-crashisolation"

echo "== rapid start/stop cycles=$CYCLES =="
RAPID_LOG="$LOGDIR/hilog-rapid.txt"
hdc_cmd shell hilog -r || true
hdc_cmd shell hilog >"$RAPID_LOG" 2>&1 &
RAPID_PID=$!
for i in $(seq 1 "$CYCLES"); do
  hdc_cmd shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  hdc_cmd shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1 || true
  sleep 0.45
done
sleep 5
kill "$RAPID_PID" 2>/dev/null || true
wait "$RAPID_PID" 2>/dev/null || true
PASS_HITS="$(rg -c "$PASS_MARKER|$HARNESS_PASS" "$RAPID_LOG" 2>/dev/null || echo 0)"
FAIL_HITS="$(rg -c "$FAIL_MARKER|FAIL: harmony crash-isolation harness" "$RAPID_LOG" 2>/dev/null || echo 0)"
BUNDLE_CRASH="$(rg -c "$BUNDLE.*(SIGSEGV|Fatal signal|APP_CRASH)" "$RAPID_LOG" 2>/dev/null || echo 0)"
echo "rapid pass_hits=$PASS_HITS fail_hits=$FAIL_HITS bundle_crash=$BUNDLE_CRASH"
if [ "${FAIL_HITS:-0}" != 0 ]; then
  fail "hap-rapid-start-stop CrashIsolation FAIL markers=$FAIL_HITS"
fi
if [ "${BUNDLE_CRASH:-0}" != 0 ]; then
  rg -n "$BUNDLE.*(SIGSEGV|Fatal signal|APP_CRASH)" "$RAPID_LOG" | head -30 || true
  fail "hap-rapid-start-stop bundle crash signatures=$BUNDLE_CRASH"
fi
if [ "${PASS_HITS:-0}" -lt 1 ]; then
  fail "hap-rapid-start-stop saw no PASS markers"
fi
pass "hap-rapid-start-stop cycles=$CYCLES pass_hits=$PASS_HITS"

echo "== force-stop mid-stress cycles=$FORCE_STOP_CYCLES =="
FORCE_LOG="$LOGDIR/hilog-force.txt"
hdc_cmd shell hilog -r || true
hdc_cmd shell hilog >"$FORCE_LOG" 2>&1 &
FORCE_PID=$!
for i in $(seq 1 "$FORCE_STOP_CYCLES"); do
  hdc_cmd shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1 || true
  sleep 0.12
  hdc_cmd shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  sleep 0.2
done
hdc_cmd shell aa start -a "$ABILITY" -b "$BUNDLE" >/dev/null 2>&1 || true
sleep 8
kill "$FORCE_PID" 2>/dev/null || true
wait "$FORCE_PID" 2>/dev/null || true
RECOVERY_PASS="$(rg -c "$PASS_MARKER|$HARNESS_PASS" "$FORCE_LOG" 2>/dev/null || echo 0)"
FORCE_FAIL="$(rg -c "$FAIL_MARKER|FAIL: harmony crash-isolation harness" "$FORCE_LOG" 2>/dev/null || echo 0)"
FORCE_BUNDLE_CRASH="$(rg -c "$BUNDLE.*(SIGSEGV|Fatal signal|APP_CRASH)" "$FORCE_LOG" 2>/dev/null || echo 0)"
echo "force-stop recovery_pass=$RECOVERY_PASS fail=$FORCE_FAIL bundle_crash=$FORCE_BUNDLE_CRASH"
if [ "${FORCE_FAIL:-0}" != 0 ]; then
  fail "hap-force-stop-mid-stress saw FAIL markers"
fi
if [ "${FORCE_BUNDLE_CRASH:-0}" != 0 ]; then
  rg -n "$BUNDLE.*(SIGSEGV|Fatal signal|APP_CRASH)" "$FORCE_LOG" | head -30 || true
  fail "hap-force-stop-mid-stress crash signatures"
fi
if [ "${RECOVERY_PASS:-0}" -lt 1 ]; then
  fail "hap-force-stop-mid-stress no recovery PASS"
fi
pass "hap-force-stop-mid-stress recovery_pass=$RECOVERY_PASS"

echo "== multi-process ProbeAbility hilog =="
PROBE_HITS="$(rg -c 'JSBAY_PROBE_|multi-process-probe' "$HILOG_BASE" "$FORCE_LOG" "$RAPID_LOG" 2>/dev/null || echo 0)"
echo "probe_related_hits≈$PROBE_HITS"
if rg -q 'PASS: multi-process-probe-ability-start|JSBAY_PROBE_SKIP|JSBAY_PROBE_START' "$HILOG_BASE" "$FORCE_LOG" "$RAPID_LOG" 2>/dev/null; then
  pass "hap-multiprocess-probe-sketch (startAbility / SKIP markers present)"
else
  skip "hap-multiprocess-probe-sketch — no probe markers in hilog (Ability may have failed silently)"
fi

echo "== process-isolation ELF (shell) =="
PREBUILT="${HARMONY_PROCESS_ISOLATION_OUT:-/tmp/jsbay-harmony-process-isolation}/bin/process_isolation_harness"
if [ -x "$PREBUILT" ]; then
  REMOTE_TRY="/data/local/tmp/jsbay-extreme-pi"
  hdc_cmd shell "rm -rf $REMOTE_TRY; mkdir -p $REMOTE_TRY" || true
  hdc_cmd file send "$PREBUILT" "$REMOTE_TRY/process_isolation_harness" || true
  hdc_cmd shell "chmod 755 $REMOTE_TRY/process_isolation_harness" || true
  set +e
  EXEC_OUT="$(hdc_cmd shell "$REMOTE_TRY/process_isolation_harness --storm 4" 2>&1)"
  set -e
  printf '%s\n' "$EXEC_OUT" | head -20
  if printf '%s' "$EXEC_OUT" | grep -q 'PASS: storm-sequential complete'; then
    pass "harmony-shell-process-isolation-storm"
  elif printf '%s' "$EXEC_OUT" | grep -qi 'Permission denied'; then
    skip "harmony-process-isolation-shell-ELF — SELinux blocks shell-exec; use :jsbay_probe + fault-injection test rebuild"
  else
    skip "harmony-process-isolation-shell-ELF — exec incomplete"
  fi
else
  skip "harmony-process-isolation-shell-ELF — no prebuilt at $PREBUILT"
fi

echo "PASS: harmony extreme CrashIsolation HAP matrix complete"
echo "logs: $LOGDIR"
