#!/usr/bin/env bash
# iOS Simulator: Zig/native abort kills only the child process.
# Builds a fault-injection archive WITHOUT -Dapple-package (product packaging forbids it),
# links tests/process-isolation/harness.c for iphonesimulator, runs via simctl spawn.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIM_UDID="${JSBAY_IOS_SIM_UDID:?set JSBAY_IOS_SIM_UDID to a Booted simulator UDID}"
BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"
OUT="${IOS_PROCESS_ISOLATION_OUT:-/tmp/jsbay-ios-process-isolation}"
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; }

echo "== simulator =="
STATE="$(xcrun simctl list devices | grep "$SIM_UDID" || true)"
echo "$STATE"
printf '%s' "$STATE" | grep -q Booted || fail "simulator $SIM_UDID not Booted"

rm -rf "$OUT"
mkdir -p "$OUT/default" "$OUT/fault" "$OUT/bin"

IOS_SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios14.0-simulator
ZIG_TARGET=aarch64-ios.14.0-simulator

echo "== 1) default ios-sim library-only (no fault-injection, no apple-package) =="
(cd "$ROOT" && zig build -Dbackend="$BACKEND" -Doptimize="$OPTIMIZE" -Dlibrary-only=true \
  -Dtarget="$ZIG_TARGET" "-Dapple-sysroot=$IOS_SIM_SDK" --prefix "$OUT/default")
DEFAULT_A="$OUT/default/lib/libjsbay.a"
test -f "$DEFAULT_A"
if nm "$DEFAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  fail "default ios-sim archive exports jsbay_test_trigger_native_fault"
fi
pass "ios-sim-default-no-fault-symbol"

echo "== 2) fault-injection ios-sim library (NOT apple-package) =="
# build.zig refuses -Dfault-injection with -Dapple-package; we never set apple-package here.
(cd "$ROOT" && zig build -Dbackend="$BACKEND" -Doptimize="$OPTIMIZE" -Dlibrary-only=true \
  -Dfault-injection=true -Dtarget="$ZIG_TARGET" "-Dapple-sysroot=$IOS_SIM_SDK" --prefix "$OUT/fault")
FAULT_A="$OUT/fault/lib/libjsbay.a"
test -f "$FAULT_A"
if ! nm "$FAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  fail "fault-injection ios-sim archive missing jsbay_test_trigger_native_fault"
fi
pass "ios-sim-fault-injection-has-symbol"

# Reject accidental apple-package combination in this script's contract.
if (cd "$ROOT" && zig build -Dbackend="$BACKEND" -Dlibrary-only=true -Dfault-injection=true \
    -Dapple-package=true -Dtarget="$ZIG_TARGET" --prefix "$OUT/reject" 2>"$OUT/reject.log"); then
  fail "build.zig should reject fault-injection + apple-package"
else
  pass "build-rejects-fault-injection-with-apple-package"
fi

echo "== 3) link harness for iphonesimulator =="
# Prefer linking against the static archive (same as host process-isolation).
xcrun --sdk iphonesimulator clang -std=c11 -Wall -Wextra -Werror \
  -target "$TARGET" -isysroot "$IOS_SIM_SDK" \
  -I"$ROOT/include" -I"$ROOT/tests/process-isolation" \
  "$ROOT/tests/process-isolation/harness.c" "$FAULT_A" \
  -framework Foundation -framework JavaScriptCore -lm \
  -o "$OUT/bin/process_isolation_harness"
codesign -s - --force "$OUT/bin/process_isolation_harness"
pass "linked-ios-sim-process-isolation-harness"

echo "== 4) run via simctl spawn =="
set +e
HARNESS_OUT="$(xcrun simctl spawn "$SIM_UDID" "$OUT/bin/process_isolation_harness" 2>&1)"
HARNESS_RC=$?
set -e
printf '%s\n' "$HARNESS_OUT"
echo "harness_exit=$HARNESS_RC"

if [ "$HARNESS_RC" -ne 0 ] || ! printf '%s' "$HARNESS_OUT" | grep -q 'PASS: process-isolation harness complete'; then
  echo "NOTE: simctl spawn path failed; trying install+launch UIKit wrapper fallback is not required — reporting FAIL unless interim host-linked path requested"
  # Interim: also try running under dyld sim if spawn cannot exec host-path binary.
  # Copy into sim data container and retry.
  SIM_DATA="$(xcrun simctl get_app_container "$SIM_UDID" com.apple.springboard data 2>/dev/null || true)"
  DEST_DIR="${TMPDIR:-/tmp}/jsbay-ios-sim-harness-copy"
  mkdir -p "$DEST_DIR"
  cp "$OUT/bin/process_isolation_harness" "$DEST_DIR/process_isolation_harness"
  codesign -s - --force "$DEST_DIR/process_isolation_harness"
  set +e
  HARNESS_OUT2="$(xcrun simctl spawn "$SIM_UDID" "$DEST_DIR/process_isolation_harness" 2>&1)"
  HARNESS_RC2=$?
  set -e
  printf '%s\n' "$HARNESS_OUT2"
  echo "harness_exit_retry=$HARNESS_RC2"
  if [ "$HARNESS_RC2" -eq 0 ] && printf '%s' "$HARNESS_OUT2" | grep -q 'PASS: process-isolation harness complete'; then
    HARNESS_OUT="$HARNESS_OUT2"
    HARNESS_RC=0
  else
    fail "ios-sim harness (simctl spawn) exit=$HARNESS_RC / retry=$HARNESS_RC2"
  fi
fi

printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-survives-abort-child' || fail "missing parent-survives-abort-child"
printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-survives-segfault-child' || fail "missing parent-survives-segfault-child"
pass "ios-simulator Zig-abort process-isolation"
echo "PASS: ios process-isolation sim run complete"
