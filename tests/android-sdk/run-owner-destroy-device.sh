#!/usr/bin/env bash
# Independent diagnostic core plus production JNI/SDK, executed on real ART.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${OWNER_DESTROY_OUT:?set a new evidence output directory}"
BACKEND="${OWNER_DESTROY_BACKEND:-quickjs_ng}"
if [ "${OWNER_DESTROY_SKIP_BUILD:-false}" = true ]; then
    COMMIT="$(<"$OUT/COMMIT")"
    if [ "${OWNER_DESTROY_COMMIT:-$COMMIT}" != "$COMMIT" ]; then echo "Commit mismatch" >&2; exit 2; fi
else
    COMMIT="${OWNER_DESTROY_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"
fi
SDK="${ANDROID_HOME:?}"; NDK="${ANDROID_NDK_HOME:?}"; JAVA="${JAVA_HOME:?}"
KOTLIN="${KOTLIN_GRADLE_LIB:?}"
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
case "$BACKEND" in quickjs|quickjs_ng) ;; *) echo "Unsupported SDK backend" >&2; exit 2;; esac
if [ "${OWNER_DESTROY_SKIP_BUILD:-false}" != true ]; then
    if [ -e "$OUT" ]; then echo "Refusing to overwrite evidence: $OUT" >&2; exit 2; fi
    mkdir -p "$OUT"/{objects,libs,classes,dex}
    cd "$ROOT"
    ANDROID_UNIT_TEST_OUT="$OUT/link-env" ANDROID_API=24 bash "$ROOT/scripts/android-unit-tests/prepare-link-env.sh"
    zig build -Dandroid-libc="$OUT/link-env/android-libc.txt" -Dbackend="$BACKEND" -Dshared=false -Dlibrary-only=true -Dfault-injection=true -Doptimize=ReleaseSafe -Dcpu=baseline -Dgit-commit="$COMMIT" -Dtarget=x86_64-linux-android.24 -Dandroid-lib-dir="$OUT/link-env/bionic-stubs" --prefix "$OUT/core"
    (cd "$OUT/objects" && "$BIN/llvm-ar" x "$OUT/core/lib/libjsbay.a")
    "$BIN/x86_64-linux-android24-clang" -shared "$OUT/objects/"*.o "$ROOT/scripts/android-unit-tests/zig_probe_stack_x86_64.S" -Wl,-z,defs -Wl,-soname,libjsbay.so -lm -ldl -o "$OUT/libs/libjsbay.so"
    "$BIN/x86_64-linux-android24-clang" -shared -fPIC -Wall -Wextra -Werror -I"$ROOT/include" "$ROOT/sdk/android/jsbay/src/main/cpp/jsbay_android.c" -L"$OUT/libs" -ljsbay -llog -Wl,-z,defs -o "$OUT/libs/libjsbay_android.so"
    "$BIN/x86_64-linux-android24-clang" -shared -fPIC -Wall -Wextra -Werror -I"$ROOT/include" "$ROOT/tests/android-sdk/owner_destroy_probe.c" -L"$OUT/libs" -ljsbay -ldl -Wl,-z,defs -o "$OUT/libs/libjsbay_owner_probe.so"
    "$JAVA/bin/java" -cp "$KOTLIN/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -classpath "$SDK/platforms/android-35/android.jar:$KOTLIN/kotlin-stdlib-1.9.22.jar:$KOTLIN/annotations-24.0.1.jar" -d "$OUT/classes" "$ROOT"/sdk/android/jsbay/src/main/kotlin/io/jsbay/*.kt "$ROOT/tests/android-sdk/OwnerDestroyMain.kt"
    "$JAVA/bin/javac" -cp "$OUT/classes:$KOTLIN/kotlin-stdlib-1.9.22.jar" -d "$OUT/classes" "$ROOT/tests/android-sdk/OwnerCloseJava.java"
    "$JAVA/bin/jar" --create --file "$OUT/consumer.jar" -C "$OUT/classes" .
    "$SDK/build-tools/35.0.0/d8" --min-api 24 --output "$OUT/dex" "$OUT/consumer.jar" "$KOTLIN/kotlin-stdlib-1.9.22.jar" "$KOTLIN/annotations-24.0.1.jar"
    printf '%s\n' "$COMMIT" > "$OUT/COMMIT"
fi
if [ "${OWNER_DESTROY_BUILD_ONLY:-false}" = true ]; then exit 0; fi
ADB="${ADB:-adb}"; SERIAL="${ANDROID_SERIAL:?}"; REMOTE="${OWNER_DESTROY_REMOTE:-/data/local/tmp/jsbay-owner-sdk}"
LABEL="${OWNER_DESTROY_RUN_LABEL:-$SERIAL}"
LOG="$OUT/art-$LABEL.log"
if [ -e "$LOG" ]; then echo "Refusing to overwrite run log: $LOG" >&2; exit 2; fi
"$ADB" -s "$SERIAL" shell "mkdir -p '$REMOTE'"
"$ADB" -s "$SERIAL" push "$OUT/dex/classes.dex" "$REMOTE/"
for lib in "$OUT/libs/"*.so; do "$ADB" -s "$SERIAL" push "$lib" "$REMOTE/"; done
# API 24 shell need not ship sha256sum. Pull and compare the actual deployed bytes.
PULLED="$OUT/deployed-$LABEL"
mkdir "$PULLED"
"$ADB" -s "$SERIAL" pull "$REMOTE/classes.dex" "$PULLED/"
cmp "$OUT/dex/classes.dex" "$PULLED/classes.dex"
for lib in "$OUT/libs/"*.so; do
    name="$(basename "$lib")"
    "$ADB" -s "$SERIAL" pull "$REMOTE/$name" "$PULLED/"
    cmp "$lib" "$PULLED/$name"
done
sha256sum "$PULLED/"* | tee -a "$LOG"
for mode in normal owner-exited looper-exited bounded-close; do
    "$ADB" -s "$SERIAL" shell "CLASSPATH='$REMOTE/classes.dex' LD_LIBRARY_PATH='$REMOTE' app_process -Djava.io.tmpdir='$REMOTE' -Djsbay.expectedCommit='$COMMIT' / io.jsbay.OwnerDestroyMain '$mode'" 2>&1 | tee -a "$LOG"
done
