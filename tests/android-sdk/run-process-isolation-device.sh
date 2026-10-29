#!/usr/bin/env bash
# Android device: Zig/native abort kills only the child process.
# Builds a test-only fault-injection .so into a SEPARATE dir (never publish jniLibs),
# links tests/process-isolation/harness.c with NDK, pushes to /data/local/tmp, runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADB="${ADB:-adb}"
ADB_SERVER_PORT="${ADB_SERVER_PORT:-}"
SERIAL="${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb device serial}"
FAULT_OUT="${JSBAY_ANDROID_FAULT_OUT:-/tmp/jsbay-android-fault-injection/jniLibs}"
WORK="${ANDROID_PROCESS_ISOLATION_OUT:-/tmp/jsbay-android-process-isolation}"
REMOTE="${ANDROID_PROCESS_ISOLATION_REMOTE:-/data/local/tmp/jsbay-process-isolation}"
ANDROID_API_LEVEL=24
QUICKJS_BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

adb_cmd() {
  if [ -n "${ADB_SERVER_PORT:-}" ]; then
    ADB_SERVER_PORT="$ADB_SERVER_PORT" "$ADB" -s "$SERIAL" "$@"
  else
    "$ADB" -s "$SERIAL" "$@"
  fi
}

NDK_BIN=""
if [ -d "${ANDROID_NDK_HOME:-}" ]; then
  NDK_BIN="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -maxdepth 2 -name bin 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$NDK_BIN" ]; then
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
    [ -n "$sdk" ] && [ -d "$sdk/ndk" ] || continue
    NDK_BIN="$(ls -d "$sdk"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | tail -n 1 || true)"
    [ -n "$NDK_BIN" ] && break
  done
fi
CLANG="$NDK_BIN/aarch64-linux-android${ANDROID_API_LEVEL}-clang"
test -x "$CLANG" || fail "NDK clang missing: $CLANG"
test -x "$ADB" || fail "adb missing: $ADB"

echo "== device =="
adb_cmd get-state | tr -d '\r' | grep -qx device || fail "device $SERIAL not ready"
ABI="$(adb_cmd shell getprop ro.product.cpu.abi | tr -d '\r')"
echo "serial=$SERIAL abi=$ABI"
case "$ABI" in
  arm64-v8a|arm64) ;;
  *) fail "expected arm64 device, got $ABI" ;;
esac

echo "== build fault-injection arm64 .so (separate OUT) =="
if [ "${SKIP_FAULT_BUILD:-0}" = 1 ] && [ -f "$FAULT_OUT/arm64-v8a/libjsbay.so" ]; then
  echo "NOTE: SKIP_FAULT_BUILD=1 reusing $FAULT_OUT/arm64-v8a/libjsbay.so"
else
  JSBAY_ANDROID_FAULT_OUT="$FAULT_OUT" QUICKJS_BACKEND="$QUICKJS_BACKEND" \
    bash "$ROOT/tests/android-sdk/build-fault-injection-arm64.sh" "$FAULT_OUT"
fi
SO="$FAULT_OUT/arm64-v8a/libjsbay.so"
ARCHIVE="$FAULT_OUT/arm64-v8a/libjsbay.a"
test -f "$SO"
# ARCHIVE kept for optional static relink; may be absent if only .so needed.
[ -f "$ARCHIVE" ] || echo "NOTE: no .a beside .so (dynamic link only)"

# Sanity: publish jniLibs (if present) must still lack the fault symbol.
PUBLISH_SO="$ROOT/build-android/jniLibs/arm64-v8a/libjsbay.so"
if [ -f "$PUBLISH_SO" ]; then
  if "$NDK_BIN/llvm-nm" "$PUBLISH_SO" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
    fail "publish jniLibs unexpectedly exports jsbay_test_trigger_native_fault"
  fi
  pass "publish-jniLibs-no-fault-symbol"
else
  echo "NOTE: no publish jniLibs at $PUBLISH_SO (skip publish nm check)"
fi

echo "== link on-device harness (dynamic against fault .so) =="
rm -rf "$WORK"
mkdir -p "$WORK/bin"
# Prefer dynamic link so the device loads the same fault-injection .so we nm-checked.
"$CLANG" -std=c11 -Wall -Wextra -Werror -fPIE -pie \
  -I"$ROOT/include" -I"$ROOT/tests/process-isolation" \
  "$ROOT/tests/process-isolation/harness.c" \
  -L"$FAULT_OUT/arm64-v8a" -ljsbay -Wl,-rpath,'$ORIGIN' -lm -ldl \
  -o "$WORK/bin/process_isolation_harness"
test -x "$WORK/bin/process_isolation_harness"
pass "linked-android-process-isolation-harness"

echo "== push + run on device =="
adb_cmd shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
adb_cmd push "$WORK/bin/process_isolation_harness" "$SO" "$REMOTE/"
adb_cmd shell "chmod 755 '$REMOTE/process_isolation_harness'"
adb_cmd shell "ls -la '$REMOTE'"
# Verify the real .so landed (do NOT ln -sf onto itself — that replaces the file with a broken symlink).
adb_cmd shell "test -f '$REMOTE/libjsbay.so' -a ! -L '$REMOTE/libjsbay.so'" || fail "libjsbay.so missing or became a symlink on device"

set +e
HARNESS_OUT="$(adb_cmd shell "cd '$REMOTE' && LD_LIBRARY_PATH='$REMOTE' ./process_isolation_harness" 2>&1)"
HARNESS_RC=$?
set -e
printf '%s\n' "$HARNESS_OUT"
echo "harness_exit=$HARNESS_RC"

# adb shell may wrap signal deaths as 255; parent harness itself must exit 0.
if [ "$HARNESS_RC" -ne 0 ]; then
  fail "device harness exit=$HARNESS_RC"
fi
printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-survives-abort-child' \
  || fail "missing parent-survives-abort-child"
printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-survives-segfault-child' \
  || fail "missing parent-survives-segfault-child"
printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-continues-after-fault' \
  || fail "missing parent-continues-after-fault"
printf '%s' "$HARNESS_OUT" | grep -q 'PASS: process-isolation harness complete' \
  || fail "missing final PASS"

pass "android-device Zig-abort process-isolation"
echo "PASS: android process-isolation device run complete"
