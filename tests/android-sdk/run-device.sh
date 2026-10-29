#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JNI_LIBS="${1:?usage: run-device.sh <jniLibs directory>}"
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

OUT="${ANDROID_DEVICE_TEST_OUT:-${TMPDIR:-/tmp}/jsbay-android-device}"
REMOTE="${ANDROID_DEVICE_TEST_REMOTE:-/data/local/tmp/jsbay-android-sdk}"
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"
SDK_CLASSES_PATH="$OUT/classes"
KOTLIN_SOURCES=("$ROOT/tests/android-sdk/KotlinConsumer.kt")
if [ -n "$SDK_CLASSES_JAR" ]; then
    test -f "$SDK_CLASSES_JAR"
    if "$JDK_HOME/bin/jar" tf "$SDK_CLASSES_JAR" | awk '/(^|\/)\.\.?($|\/)|^\// { found = 1 } END { exit !found }'; then
        echo "ERROR: unsafe class entry in $SDK_CLASSES_JAR" >&2
        exit 1
    fi
    SDK_CLASSES_PATH="$OUT/sdk-classes"
    mkdir -p "$SDK_CLASSES_PATH"
    (cd "$SDK_CLASSES_PATH" && "$JDK_HOME/bin/jar" xf "$SDK_CLASSES_JAR")
else
    KOTLIN_SOURCES=("$ROOT"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt "${KOTLIN_SOURCES[@]}")
fi
"$JDK_HOME/bin/java" -cp "$GRADLE_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -classpath "$SDK_ROOT/platforms/android-35/android.jar:$SDK_CLASSES_PATH:$KOTLIN_STDLIB:$KOTLIN_ANNOTATIONS" -d "$OUT/classes" "${KOTLIN_SOURCES[@]}"
"$JDK_HOME/bin/javac" -encoding UTF-8 -cp "$SDK_ROOT/platforms/android-35/android.jar:$SDK_CLASSES_PATH:$OUT/classes:$KOTLIN_STDLIB" -d "$OUT/classes" "$ROOT"/tests/android-sdk/JavaConsumer.java "$ROOT"/tests/android-sdk/ConsumerMain.java "$ROOT"/tests/android-sdk/DeviceLoopMain.java
if [ -n "$SDK_CLASSES_JAR" ]; then
    cp -R "$SDK_CLASSES_PATH"/. "$OUT/classes"/
fi
"$JDK_HOME/bin/jar" --create --file "$OUT/consumer.jar" -C "$OUT/classes" .
mkdir -p "$OUT/api24-dex"
"$BUILD_TOOLS/d8" --min-api 24 --output "$OUT/api24-dex" "$OUT/consumer.jar"
if strings "$OUT/api24-dex/classes.dex" | grep -Eq 'Ljava/nio/file/(Files|Path);'; then
    echo 'consumer DEX references an API 26 java.nio.file class' >&2
    exit 1
fi
"$BUILD_TOOLS/d8" --min-api 24 --output "$OUT/dex" "$OUT/consumer.jar" "$KOTLIN_STDLIB" "$KOTLIN_ANNOTATIONS"
"$ADB" shell "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
push_android_device_payload "$OUT/dex/classes.dex" "$REMOTE/"
run_android_device_consumer "$REMOTE"
