#!/usr/bin/env bash
# Extreme Android device matrix: Java adversarial cases + Zig abort/segfault storm.
# Publish jniLibs stay fault-free; storm links a SEPARATE fault-injection .so.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADB="${ADB:-adb}"
ADB_SERVER_PORT="${ADB_SERVER_PORT:-}"
SERIAL="${ANDROID_SERIAL:?set ANDROID_SERIAL to the adb device serial}"
JNI_LIBS="${1:-$ROOT/build-android/jniLibs}"
JDK_HOME="${JAVA_HOME:?set JAVA_HOME to JDK 17}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?set ANDROID_HOME}}"
GRADLE_LIB="${KOTLIN_GRADLE_LIB:-$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d | head -1)}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-}"
FAULT_OUT="${JSBAY_ANDROID_FAULT_OUT:-/tmp/jsbay-android-fault-injection/jniLibs}"
WORK="${ANDROID_EXTREME_OUT:-/tmp/jsbay-android-extreme}"
REMOTE_JAVA="${ANDROID_EXTREME_JAVA_REMOTE:-/data/local/tmp/jsbay-android-extreme}"
REMOTE_STORM="${ANDROID_EXTREME_STORM_REMOTE:-/data/local/tmp/jsbay-android-extreme-storm}"
STORM_N="${EXTREME_STORM_N:-24}"
STORM_PAR_N="${EXTREME_STORM_PARALLEL_N:-16}"
ANDROID_API_LEVEL=24

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

adb_cmd() {
  if [ -n "${ADB_SERVER_PORT:-}" ]; then
    ADB_SERVER_PORT="$ADB_SERVER_PORT" "$ADB" -s "$SERIAL" "$@"
  else
    "$ADB" -s "$SERIAL" "$@"
  fi
}

test -n "$GRADLE_LIB" || fail "gradle lib missing"
KOTLIN_STDLIB="$(find "$GRADLE_LIB" -maxdepth 1 -name 'kotlin-stdlib-*.jar' -print -quit)"
KOTLIN_ANNOTATIONS="$(find "$GRADLE_LIB" -maxdepth 1 -name 'annotations-*.jar' -print -quit)"
test -f "$KOTLIN_STDLIB" && test -f "$KOTLIN_ANNOTATIONS"
if [ -z "$BUILD_TOOLS" ]; then BUILD_TOOLS="$(find "$SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"; fi
test -x "$BUILD_TOOLS/d8"
source "$ROOT/tests/android-sdk/android-device-lib.sh"

adb_cmd get-state | tr -d '\r' | grep -qx device || fail "device $SERIAL not ready"
require_android_device_abi "$JNI_LIBS"

echo "== 1) Java extreme matrix on device =="
rm -rf "$WORK/java"
mkdir -p "$WORK/java/classes" "$WORK/java/dex"
"$JDK_HOME/bin/java" -cp "$GRADLE_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib \
  -classpath "$SDK_ROOT/platforms/android-35/android.jar:$KOTLIN_STDLIB:$KOTLIN_ANNOTATIONS" \
  -d "$WORK/java/classes" "$ROOT"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt
"$JDK_HOME/bin/javac" -encoding UTF-8 \
  -cp "$SDK_ROOT/platforms/android-35/android.jar:$WORK/java/classes:$KOTLIN_STDLIB" \
  -d "$WORK/java/classes" "$ROOT/tests/android-sdk/ExtremeMatrixMain.java"
"$JDK_HOME/bin/jar" --create --file "$WORK/java/consumer.jar" -C "$WORK/java/classes" .
"$BUILD_TOOLS/d8" --min-api 24 --output "$WORK/java/dex" "$WORK/java/consumer.jar" "$KOTLIN_STDLIB" "$KOTLIN_ANNOTATIONS"
adb_cmd shell "rm -rf '$REMOTE_JAVA' && mkdir -p '$REMOTE_JAVA'"
adb_cmd push "$WORK/java/dex/classes.dex" "$ANDROID_DEVICE_CORE" "$ANDROID_DEVICE_ADAPTER" "$REMOTE_JAVA/"

set +e
JAVA_OUT="$(adb_cmd shell "CLASSPATH='$REMOTE_JAVA/classes.dex' LD_LIBRARY_PATH='$REMOTE_JAVA' app_process -Djava.io.tmpdir='$REMOTE_JAVA' / io.jsbay.consumer.ExtremeMatrixMain" 2>&1)"
JAVA_RC=$?
set -e
printf '%s\n' "$JAVA_OUT"
echo "java_extreme_exit=$JAVA_RC"
[ "$JAVA_RC" -eq 0 ] || fail "java extreme exit=$JAVA_RC"
printf '%s' "$JAVA_OUT" | grep -q 'PASS: extreme-matrix harness complete' \
  || fail "missing java extreme completion"
pass "android-extreme-java-matrix"

echo "== 2) publish .so must lack fault symbol =="
NDK_BIN=""
for sdk in "$SDK_ROOT"; do
  [ -d "$sdk/ndk" ] || continue
  NDK_BIN="$(ls -d "$sdk"/ndk/*/toolchains/llvm/prebuilt/*/bin 2>/dev/null | tail -n 1 || true)"
  [ -n "$NDK_BIN" ] && break
done
CLANG="$NDK_BIN/aarch64-linux-android${ANDROID_API_LEVEL}-clang"
test -x "$CLANG" || fail "NDK clang missing"
PUBLISH_SO="$JNI_LIBS/arm64-v8a/libjsbay.so"
if "$NDK_BIN/llvm-nm" "$PUBLISH_SO" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  fail "publish jniLibs exports fault symbol"
fi
pass "publish-jniLibs-no-fault-symbol"

echo "== 3) Zig abort/segfault storm on device =="
if [ "${SKIP_FAULT_BUILD:-0}" = 1 ] && [ -f "$FAULT_OUT/arm64-v8a/libjsbay.so" ]; then
  echo "NOTE: reusing fault .so at $FAULT_OUT"
else
  JSBAY_ANDROID_FAULT_OUT="$FAULT_OUT" bash "$ROOT/tests/android-sdk/build-fault-injection-arm64.sh" "$FAULT_OUT"
fi
SO="$FAULT_OUT/arm64-v8a/libjsbay.so"
rm -rf "$WORK/storm"
mkdir -p "$WORK/storm/bin"
"$CLANG" -std=c11 -Wall -Wextra -Werror -fPIE -pie \
  -I"$ROOT/include" -I"$ROOT/tests/process-isolation" \
  "$ROOT/tests/process-isolation/harness.c" \
  -L"$FAULT_OUT/arm64-v8a" -ljsbay -Wl,-rpath,'$ORIGIN' -lm -ldl \
  -o "$WORK/storm/bin/process_isolation_harness"
adb_cmd shell "rm -rf '$REMOTE_STORM' && mkdir -p '$REMOTE_STORM'"
adb_cmd push "$WORK/storm/bin/process_isolation_harness" "$SO" "$REMOTE_STORM/"
adb_cmd shell "chmod 755 '$REMOTE_STORM/process_isolation_harness'"

set +e
STORM_OUT="$(adb_cmd shell "cd '$REMOTE_STORM' && LD_LIBRARY_PATH='$REMOTE_STORM' ./process_isolation_harness --storm $STORM_N" 2>&1)"
STORM_RC=$?
set -e
printf '%s\n' "$STORM_OUT"
echo "storm_exit=$STORM_RC"
[ "$STORM_RC" -eq 0 ] || fail "android storm-seq exit=$STORM_RC"
printf '%s' "$STORM_OUT" | grep -q "PASS: storm-sequential complete n=$STORM_N" \
  || fail "missing android storm-seq PASS"
pass "android-storm-sequential-$STORM_N"

set +e
PAR_OUT="$(adb_cmd shell "cd '$REMOTE_STORM' && LD_LIBRARY_PATH='$REMOTE_STORM' ./process_isolation_harness --storm-parallel $STORM_PAR_N" 2>&1)"
PAR_RC=$?
set -e
printf '%s\n' "$PAR_OUT"
echo "storm_par_exit=$PAR_RC"
[ "$PAR_RC" -eq 0 ] || fail "android storm-parallel exit=$PAR_RC"
printf '%s' "$PAR_OUT" | grep -q "PASS: storm-parallel complete n=$STORM_PAR_N" \
  || fail "missing android storm-par PASS"
pass "android-storm-parallel-$STORM_PAR_N"

echo "PASS: android extreme device matrix complete"
