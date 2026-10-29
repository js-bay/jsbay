#!/usr/bin/env bash
# Build arm64 jniLibs (+ JNI adapter) and run DeviceP0Main on a connected Android device.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADB="${ADB:-adb}"
SERIAL="${ANDROID_SERIAL:-}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?set ANDROID_HOME}}"
JDK_HOME="${JAVA_HOME:?set JAVA_HOME to JDK 17}"
NDK_HOME="${ANDROID_NDK_HOME:-$SDK_ROOT/ndk/28.2.13676358}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-}"
GRADLE_LIB="${KOTLIN_GRADLE_LIB:-$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d 2>/dev/null | head -1)}"
JNI_LIBS="${1:-$ROOT/build-android/jniLibs}"
SKIP_CORE_BUILD="${ANDROID_P0_SKIP_CORE_BUILD:-false}"

if [ -n "$SERIAL" ]; then ADB_CMD=("$ADB" -s "$SERIAL"); else ADB_CMD=("$ADB"); fi
export ADB="$ADB"
# android-device-lib uses ${ADB:-adb} as a single token; wrap via function when serial set
if [ -n "$SERIAL" ]; then
  adb() { command "$ADB" -s "$SERIAL" "$@"; }
  export -f adb
  ADB=adb
fi

test -d "$SDK_ROOT"
test -d "$NDK_HOME"
test -x "$JDK_HOME/bin/java"
test -n "$GRADLE_LIB" && test -d "$GRADLE_LIB"
if [ -z "$BUILD_TOOLS" ]; then BUILD_TOOLS="$(find "$SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"; fi
test -x "$BUILD_TOOLS/d8"

NDK_BIN="$(ls -d "$NDK_HOME"/toolchains/llvm/prebuilt/*/bin | head -1)"
test -x "$NDK_BIN/aarch64-linux-android24-clang"

if [ "$SKIP_CORE_BUILD" != true ]; then
  echo "==> Building Android core jniLibs"
  ANDROID_NDK_HOME="$NDK_HOME" ANDROID_HOME="$SDK_ROOT" bash "$ROOT/build-android.sh" "$JNI_LIBS"
fi
test -f "$JNI_LIBS/arm64-v8a/libjsbay.so"

echo "==> Linking libjsbay_android.so (arm64-v8a)"
JNI_INC="$NDK_HOME/toolchains/llvm/prebuilt/$(ls "$NDK_HOME/toolchains/llvm/prebuilt" | head -1)/sysroot/usr/include"
# NDK JNI headers
for cand in \
  "$NDK_HOME/toolchains/llvm/prebuilt"/*/sysroot/usr/include \
  "$JDK_HOME/include"; do
  if [ -f "$cand/jni.h" ] || [ -f "$cand/android/jni.h" ]; then JNI_INC="$cand"; break; fi
done
# Prefer NDK jni.h under sysroot
SYSROOT="$(cd "$NDK_BIN/../sysroot" && pwd)"
"$NDK_BIN/aarch64-linux-android24-clang" -shared -fPIC \
  -I"$ROOT/include" -I"$SYSROOT/usr/include" \
  "$ROOT/sdk/android/jsbay/src/main/cpp/jsbay_android.c" \
  -L"$JNI_LIBS/arm64-v8a" -ljsbay -llog \
  -Wl,-rpath-link,"$JNI_LIBS/arm64-v8a" \
  -o "$JNI_LIBS/arm64-v8a/libjsbay_android.so"
test -s "$JNI_LIBS/arm64-v8a/libjsbay_android.so"

source "$ROOT/tests/android-sdk/android-device-lib.sh"
require_android_device_abi "$JNI_LIBS"

KOTLIN_STDLIB="$(find "$GRADLE_LIB" -maxdepth 1 -name 'kotlin-stdlib-*.jar' -print -quit)"
KOTLIN_ANNOTATIONS="$(find "$GRADLE_LIB" -maxdepth 1 -name 'annotations-*.jar' -print -quit)"
test -f "$KOTLIN_STDLIB" && test -f "$KOTLIN_ANNOTATIONS"

OUT="${ANDROID_DEVICE_TEST_OUT:-${TMPDIR:-/tmp}/jsbay-android-device-p0}"
REMOTE="${ANDROID_DEVICE_TEST_REMOTE:-/data/local/tmp/jsbay-android-p0}"
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

echo "==> Compiling Kotlin SDK + DeviceP0Main"
"$JDK_HOME/bin/java" -cp "$GRADLE_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib \
  -classpath "$SDK_ROOT/platforms/android-35/android.jar:$KOTLIN_STDLIB:$KOTLIN_ANNOTATIONS" \
  -d "$OUT/classes" \
  "$ROOT"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt \
  "$ROOT/tests/android-sdk/DeviceP0Main.kt"

"$JDK_HOME/bin/jar" --create --file "$OUT/consumer.jar" -C "$OUT/classes" .
"$BUILD_TOOLS/d8" --min-api 24 --output "$OUT/dex" "$OUT/consumer.jar" "$KOTLIN_STDLIB" "$KOTLIN_ANNOTATIONS"

echo "==> Pushing to $REMOTE"
"${ADB_CMD[@]}" shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
# push_android_device_payload uses ADB env
push_android_device_payload "$OUT/dex/classes.dex" "$REMOTE/"

echo "==> Running DeviceP0Main on device"
LOG="$OUT/device-p0.log"
set +e
"${ADB_CMD[@]}" shell "CLASSPATH='$REMOTE/classes.dex' LD_LIBRARY_PATH='$REMOTE' app_process -Djava.io.tmpdir='$REMOTE' / io.jsbay.consumer.DeviceP0Main" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e
grep -F 'PASS: Android device P0 keep-alive' "$LOG"
grep -F 'PASS: device suspend/resume keep-alive' "$LOG"
grep -F 'PASS: device admission class + list/snapshot' "$LOG"
grep -F 'PASS: device bindSync ResolveString/ResolveBytes' "$LOG"
exit "$RC"
