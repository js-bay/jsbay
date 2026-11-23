#!/usr/bin/env bash
# Compile only the consumer against the supplied packaged SDK classes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLASSES="${1:?supply actual AAR classes.jar}"
JNI="${2:?supply extracted AAR jni directory}"
OUT="${ASYNC_CLOSE_OUT:?supply a new evidence directory}"
KOTLIN="${KOTLIN_GRADLE_LIB:?}"
SDK="${ANDROID_SDK_ROOT:?}"
if [ -e "$OUT" ]; then echo "Refusing to overwrite evidence: $OUT" >&2; exit 2; fi
mkdir -p "$OUT"/{classes,dex}
"$JAVA_HOME/bin/java" -cp "$KOTLIN/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -classpath "$CLASSES:$SDK/platforms/android-35/android.jar:$KOTLIN/kotlin-stdlib-1.9.22.jar:$KOTLIN/annotations-24.0.1.jar" -d "$OUT/classes" "$ROOT/tests/android-sdk/AsyncCloseConsumer.kt"
"$JAVA_HOME/bin/jar" --create --file "$OUT/consumer.jar" -C "$OUT/classes" .
if [ "${ASYNC_CLOSE_R8:-false}" = true ]; then
    printf '%s\n' '-keep class io.jsbay.consumer.AsyncCloseConsumer { public static void main(java.lang.String[]); }' > "$OUT/consumer.pro"
    cat "$ROOT/sdk/android/jsbay/consumer-rules.pro" >> "$OUT/consumer.pro"
    "$JAVA_HOME/bin/java" -cp "$SDK/build-tools/35.0.0/lib/d8.jar" com.android.tools.r8.R8 --release --min-api 24 --lib "$SDK/platforms/android-35/android.jar" --pg-conf "$OUT/consumer.pro" --pg-map-output "$OUT/mapping.txt" --output "$OUT/dex" "$OUT/consumer.jar" "$CLASSES" "$KOTLIN/kotlin-stdlib-1.9.22.jar" "$KOTLIN/annotations-24.0.1.jar"
else
    "$SDK/build-tools/35.0.0/d8" --min-api 24 --output "$OUT/dex" "$OUT/consumer.jar" "$CLASSES" "$KOTLIN/kotlin-stdlib-1.9.22.jar" "$KOTLIN/annotations-24.0.1.jar"
fi
ADB="${ADB:-adb}"
REMOTE="${ASYNC_CLOSE_REMOTE:-/data/local/tmp/jsbay-async-close-consumer}"
source "$ROOT/tests/android-sdk/android-device-lib.sh"
require_android_device_abi "$JNI"
"$ADB" shell "mkdir -p '$REMOTE'"
push_android_device_payload "$OUT/dex/classes.dex" "$REMOTE/"
for mode in normal quit-owner; do
    "$ADB" shell "CLASSPATH='$REMOTE/classes.dex' LD_LIBRARY_PATH='$REMOTE' app_process / io.jsbay.consumer.AsyncCloseConsumer '$mode'" 2>&1 | tee "$OUT/$mode.log"
done
