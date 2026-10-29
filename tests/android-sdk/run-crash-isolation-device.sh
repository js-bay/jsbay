#!/usr/bin/env bash
# Strict Android soft-failure / crash-isolation harness.
# Same-process native abort is still not contained here. For real Zig abort containment
# see tests/process-isolation/run.sh (Linux parent survives child SIGABRT/SIGSEGV).
# Usage: run-crash-isolation-device.sh <jniLibs directory>
# Prefer ADB that lists the device. Dual servers: try
#   ADB=/opt/homebrew/bin/adb   or   ADB_SERVER_SOCKET=tcp:localhost:5038 adb
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JNI_LIBS="${1:?usage: run-crash-isolation-device.sh <jniLibs directory>}"
ADB="${ADB:-adb}"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
JDK_HOME="${JAVA_HOME:?set JAVA_HOME to JDK 17}"
GRADLE_LIB="${KOTLIN_GRADLE_LIB:-$(find "$HOME/.gradle/wrapper/dists/gradle-8.7-bin" -path '*/gradle-8.7/lib' -type d | head -1)}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-}"
SDK_CLASSES_JAR="${JSBAY_ANDROID_CLASSES_JAR:-}"

test -n "$SDK_ROOT" && test -d "$SDK_ROOT"
test -x "$JDK_HOME/bin/java" && test -n "$GRADLE_LIB"
KOTLIN_STDLIB="$(find "$GRADLE_LIB" -maxdepth 1 -name 'kotlin-stdlib-*.jar' -print -quit)"
KOTLIN_ANNOTATIONS="$(find "$GRADLE_LIB" -maxdepth 1 -name 'annotations-*.jar' -print -quit)"
test -f "$KOTLIN_STDLIB" && test -f "$KOTLIN_ANNOTATIONS"
source "$ROOT/tests/android-sdk/android-device-lib.sh"
if [ -z "$BUILD_TOOLS" ]; then BUILD_TOOLS="$(find "$SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"; fi
test -x "$BUILD_TOOLS/d8"
"$ADB" get-state | grep -qx device
require_android_device_abi "$JNI_LIBS"

OUT="${ANDROID_CRASH_TEST_OUT:-${TMPDIR:-/tmp}/jsbay-android-crash-isolation}"
REMOTE="${ANDROID_CRASH_TEST_REMOTE:-/data/local/tmp/jsbay-android-crash-isolation}"
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"
SDK_CLASSES_PATH="$OUT/classes"
KOTLIN_SOURCES=()
if [ -n "$SDK_CLASSES_JAR" ]; then
    test -f "$SDK_CLASSES_JAR"
    SDK_CLASSES_PATH="$OUT/sdk-classes"
    mkdir -p "$SDK_CLASSES_PATH"
    (cd "$SDK_CLASSES_PATH" && "$JDK_HOME/bin/jar" xf "$SDK_CLASSES_JAR")
else
    KOTLIN_SOURCES=("$ROOT"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt)
fi
"$JDK_HOME/bin/java" -cp "$GRADLE_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib \
  -classpath "$SDK_ROOT/platforms/android-35/android.jar:$SDK_CLASSES_PATH:$KOTLIN_STDLIB:$KOTLIN_ANNOTATIONS" \
  -d "$OUT/classes" "${KOTLIN_SOURCES[@]}"
"$JDK_HOME/bin/javac" -encoding UTF-8 \
  -cp "$SDK_ROOT/platforms/android-35/android.jar:$SDK_CLASSES_PATH:$OUT/classes:$KOTLIN_STDLIB" \
  -d "$OUT/classes" "$ROOT/tests/android-sdk/CrashIsolationMain.java"
if [ -n "$SDK_CLASSES_JAR" ]; then
    cp -R "$SDK_CLASSES_PATH"/. "$OUT/classes"/
fi
"$JDK_HOME/bin/jar" --create --file "$OUT/consumer.jar" -C "$OUT/classes" .
"$BUILD_TOOLS/d8" --min-api 24 --output "$OUT/dex" "$OUT/consumer.jar" "$KOTLIN_STDLIB" "$KOTLIN_ANNOTATIONS"
"$ADB" shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
push_android_device_payload "$OUT/dex/classes.dex" "$REMOTE/"

echo "== parent soft-failure cases =="
set +e
PARENT_OUT="$("$ADB" shell "CLASSPATH='$REMOTE/classes.dex' LD_LIBRARY_PATH='$REMOTE' app_process -Djava.io.tmpdir='$REMOTE' / io.jsbay.consumer.CrashIsolationMain" 2>&1)"
PARENT_RC=$?
set -e
printf '%s\n' "$PARENT_OUT"
echo "parent_exit=$PARENT_RC"

echo "== child intentional exit (native-fault runner pattern) =="
set +e
CHILD_OUT="$("$ADB" shell "CLASSPATH='$REMOTE/classes.dex' LD_LIBRARY_PATH='$REMOTE' app_process -Djava.io.tmpdir='$REMOTE' / io.jsbay.consumer.CrashIsolationMain --crash-child" 2>&1)"
CHILD_RC=$?
set -e
printf '%s\n' "$CHILD_OUT"
echo "child_exit=$CHILD_RC"

if [ "$CHILD_RC" -eq 99 ] || printf '%s' "$CHILD_OUT" | grep -q 'PASS: crash-child'; then
  echo "PASS: native-fault-runner-pattern (child exited, parent script still running)"
else
  echo "FAIL: native-fault-runner-pattern child_exit=$CHILD_RC"
  exit 1
fi

if [ "$PARENT_RC" -ne 0 ]; then
  echo "FAIL: parent harness exit=$PARENT_RC"
  exit 1
fi
if ! printf '%s' "$PARENT_OUT" | grep -q 'PASS: crash-isolation harness complete'; then
  echo "FAIL: missing parent completion marker"
  exit 1
fi
echo "PASS: crash-isolation device run"
