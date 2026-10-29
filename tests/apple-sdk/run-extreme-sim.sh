#!/usr/bin/env bash
# Extreme iOS Simulator: process-isolation + abort/segfault storm (+ parallel).
# Never combines -Dfault-injection with -Dapple-package.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIM_UDID="${JSBAY_IOS_SIM_UDID:?set JSBAY_IOS_SIM_UDID to a Booted simulator UDID}"
BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"
OUT="${IOS_EXTREME_OUT:-/tmp/jsbay-ios-extreme}"
STORM_N="${EXTREME_STORM_N:-24}"
STORM_PAR_N="${EXTREME_STORM_PARALLEL_N:-16}"
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

echo "== simulator =="
STATE="$(xcrun simctl list devices | grep "$SIM_UDID" || true)"
echo "$STATE"
printf '%s' "$STATE" | grep -q Booted || fail "simulator $SIM_UDID not Booted"

echo "== baseline process-isolation =="
bash "$ROOT/tests/apple-sdk/run-process-isolation-sim.sh" || fail "baseline ios process-isolation"
pass "ios-baseline-process-isolation"

rm -rf "$OUT"
mkdir -p "$OUT/fault" "$OUT/bin"
IOS_SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET=arm64-apple-ios14.0-simulator
ZIG_TARGET=aarch64-ios.14.0-simulator

(cd "$ROOT" && zig build -Dbackend="$BACKEND" -Doptimize="$OPTIMIZE" -Dlibrary-only=true \
  -Dfault-injection=true -Dtarget="$ZIG_TARGET" "-Dapple-sysroot=$IOS_SIM_SDK" --prefix "$OUT/fault")
FAULT_A="$OUT/fault/lib/libjsbay.a"
test -f "$FAULT_A"
# Publish-path reject still holds.
if (cd "$ROOT" && zig build -Dbackend="$BACKEND" -Dlibrary-only=true -Dfault-injection=true \
    -Dapple-package=true -Dtarget="$ZIG_TARGET" --prefix "$OUT/reject" 2>"$OUT/reject.log"); then
  fail "build.zig should reject fault-injection + apple-package"
fi
pass "build-rejects-fault-injection-with-apple-package"

xcrun --sdk iphonesimulator clang -std=c11 -Wall -Wextra -Werror \
  -target "$TARGET" -isysroot "$IOS_SIM_SDK" \
  -I"$ROOT/include" -I"$ROOT/tests/process-isolation" \
  "$ROOT/tests/process-isolation/harness.c" "$FAULT_A" \
  -framework Foundation -framework JavaScriptCore -lm \
  -o "$OUT/bin/process_isolation_harness"
codesign -s - --force "$OUT/bin/process_isolation_harness"

run_sim() {
  local args=("$@")
  xcrun simctl spawn "$SIM_UDID" "$OUT/bin/process_isolation_harness" "${args[@]}"
}

set +e
STORM_OUT="$(run_sim --storm "$STORM_N" 2>&1)"
STORM_RC=$?
set -e
printf '%s\n' "$STORM_OUT"
echo "storm_exit=$STORM_RC"
[ "$STORM_RC" -eq 0 ] || fail "ios storm-seq exit=$STORM_RC"
printf '%s' "$STORM_OUT" | grep -q "PASS: storm-sequential complete n=$STORM_N" \
  || fail "missing ios storm-seq PASS"
pass "ios-storm-sequential-$STORM_N"

set +e
PAR_OUT="$(run_sim --storm-parallel "$STORM_PAR_N" 2>&1)"
PAR_RC=$?
set -e
printf '%s\n' "$PAR_OUT"
echo "storm_par_exit=$PAR_RC"
[ "$PAR_RC" -eq 0 ] || fail "ios storm-parallel exit=$PAR_RC"
printf '%s' "$PAR_OUT" | grep -q "PASS: storm-parallel complete n=$STORM_PAR_N" \
  || fail "missing ios storm-par PASS"
pass "ios-storm-parallel-$STORM_PAR_N"

echo "PASS: ios extreme sim matrix complete"
