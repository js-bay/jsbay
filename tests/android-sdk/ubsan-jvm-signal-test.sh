#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    echo 'SKIP: UBSan and HotSpot signal integration is macOS-only'
    exit 0
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
jdk_home=${JAVA_HOME:-$(cd "$(dirname "$(command -v javac)")/.." && pwd)}
java_bin=${JAVA:-$jdk_home/bin/java}
javac_bin=${JAVAC:-$jdk_home/bin/javac}
cc_bin=${CC:-cc}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-ubsan-jvm-signal.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

UBSAN_OPTIONS="${UBSAN_OPTIONS:+$UBSAN_OPTIONS:}print_stacktrace=1:handle_segv=1:handle_sigbus=1:handle_sigfpe=1:handle_sigill=1:handle_sigtrap=1:halt_on_error=0"
source "$root/tests/android-sdk/ubsan-jvm-env.sh"
jsbay_configure_jvm_ubsan_options
[[ ":$UBSAN_OPTIONS:" == *':print_stacktrace=1:'* ]] || { echo 'existing UBSAN_OPTIONS were not preserved' >&2; exit 1; }
for option in handle_segv=0 handle_sigbus=0 handle_sigfpe=0 handle_sigill=0 handle_sigtrap=0 halt_on_error=1 abort_on_error=0; do
    [[ ":$UBSAN_OPTIONS:" == *":$option:"* ]] || { echo "missing UBSan JVM option: $option" >&2; exit 1; }
done

cat > "$temporary/SignalProbe.java" <<'EOF'
public final class SignalProbe {
  static { System.loadLibrary("jsbay_ubsan_jvm_signal_probe"); }

  private static final class Box { int value = 7; }

  private static native int ping();
  private static native int signedOverflow();

  private static int read(Box box) { return box.value; }

  public static void main(String[] args) {
    ping();
    if (args.length != 0) {
      signedOverflow();
      return;
    }

    Box box = new Box();
    int sum = 0;
    for (int i = 0; i < 20_000_000; ++i) sum += read(box);
    try {
      read(null);
      throw new AssertionError("expected NullPointerException");
    } catch (NullPointerException expected) {
      System.out.println("PASS: HotSpot handled the implicit null check; sum=" + sum);
    }
  }
}
EOF

cat > "$temporary/signal_probe.c" <<'EOF'
#include <jni.h>
#include <limits.h>

static jint jsbay_test_ping(JNIEnv *env, jclass type) {
    (void)env;
    (void)type;
    return 0;
}

static jint jsbay_test_signed_overflow(JNIEnv *env, jclass type) {
    (void)env;
    (void)type;
    volatile int value = INT_MAX;
    return value + 1;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;

    jclass probe = (*env)->FindClass(env, "SignalProbe");
    if (probe == NULL) return JNI_ERR;

    JNINativeMethod methods[] = {
        {"ping", "()I", (void *)jsbay_test_ping},
        {"signedOverflow", "()I", (void *)jsbay_test_signed_overflow},
    };
    if ((*env)->RegisterNatives(env, probe, methods, 2) != JNI_OK) return JNI_ERR;
    return JNI_VERSION_1_6;
}
EOF

mkdir -p "$temporary/classes"
"$javac_bin" -d "$temporary/classes" "$temporary/SignalProbe.java"
"$cc_bin" -dynamiclib -fPIC -O1 -g -fsanitize=undefined -Wall -Wextra -Werror \
    -I"$jdk_home/include" -I"$jdk_home/include/darwin" \
    "$temporary/signal_probe.c" -o "$temporary/libjsbay_ubsan_jvm_signal_probe.dylib"

if UBSAN_OPTIONS="$UBSAN_OPTIONS" "$java_bin" -Xcheck:jni -Djava.library.path="$temporary" \
    -cp "$temporary/classes" SignalProbe >"$temporary/implicit-null.log" 2>&1; then
    grep -Fq 'PASS: HotSpot handled the implicit null check' "$temporary/implicit-null.log"
else
    cat "$temporary/implicit-null.log" >&2
    exit 1
fi

if UBSAN_OPTIONS="$UBSAN_OPTIONS" "$java_bin" -Xcheck:jni -Djava.library.path="$temporary" \
    -cp "$temporary/classes" SignalProbe overflow >"$temporary/signed-overflow.log" 2>&1; then
    echo 'UBSan accepted a signed integer overflow' >&2
    cat "$temporary/signed-overflow.log" >&2
    exit 1
fi
grep -Fq 'runtime error: signed integer overflow' "$temporary/signed-overflow.log"

printf 'PASS: HotSpot signal handling and UBSan instrumentation coexist\n'
