#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-android-abi-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/jni/arm64-v8a" "$TEST_ROOT/jni/x86_64" "$TEST_ROOT/bin"
touch "$TEST_ROOT/jni/arm64-v8a/libjsbay.so" "$TEST_ROOT/jni/arm64-v8a/libjsbay_android.so"
touch "$TEST_ROOT/jni/x86_64/libjsbay.so" "$TEST_ROOT/jni/x86_64/libjsbay_android.so"
cat > "$TEST_ROOT/bin/adb" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = shell ] && [ "$2" = getprop ] && [ "$3" = ro.product.cpu.abilist ]; then
    printf '%s\n' "${FAKE_ABILIST:?}"
    exit 0
fi
if [ "$1" = push ]; then
    printf '%s\n' "$*" >> "${FAKE_ADB_LOG:?}"
    exit 0
fi
if [ "$1" = shell ]; then
    printf '%s\n' "$*" >> "${FAKE_ADB_LOG:?}"
    exit 0
fi
echo "unexpected adb invocation: $*" >&2
exit 1
EOF
chmod +x "$TEST_ROOT/bin/adb"

source "$ROOT/tests/android-sdk/android-device-lib.sh"
ADB="$TEST_ROOT/bin/adb"
FAKE_ADB_LOG="$TEST_ROOT/pushes"
export FAKE_ADB_LOG

export FAKE_ABILIST='arm64-v8a,armeabi-v7a'
require_android_device_abi "$TEST_ROOT/jni"
[ "$ANDROID_DEVICE_ABI" = arm64-v8a ]
[ "$ANDROID_DEVICE_CORE" = "$TEST_ROOT/jni/arm64-v8a/libjsbay.so" ]
[ "$ANDROID_DEVICE_ADAPTER" = "$TEST_ROOT/jni/arm64-v8a/libjsbay_android.so" ]

export FAKE_ABILIST='x86_64,arm64-v8a'
require_android_device_abi "$TEST_ROOT/jni"
[ "$ANDROID_DEVICE_ABI" = x86_64 ]
[ "$ANDROID_DEVICE_CORE" = "$TEST_ROOT/jni/x86_64/libjsbay.so" ]
[ "$ANDROID_DEVICE_ADAPTER" = "$TEST_ROOT/jni/x86_64/libjsbay_android.so" ]
touch "$TEST_ROOT/classes.dex"
push_android_device_payload "$TEST_ROOT/classes.dex" /data/local/tmp/jsbay/
grep -Fx "push $TEST_ROOT/classes.dex $TEST_ROOT/jni/x86_64/libjsbay.so $TEST_ROOT/jni/x86_64/libjsbay_android.so /data/local/tmp/jsbay/" "$FAKE_ADB_LOG"
run_android_device_consumer /data/local/tmp/jsbay
grep -Fx "shell CLASSPATH='/data/local/tmp/jsbay/classes.dex' LD_LIBRARY_PATH='/data/local/tmp/jsbay' app_process -Djava.io.tmpdir='/data/local/tmp/jsbay' / io.jsbay.consumer.DeviceLoopMain" "$FAKE_ADB_LOG"

export FAKE_ABILIST='riscv64'
if require_android_device_abi "$TEST_ROOT/jni"; then
    echo 'unsupported ABI unexpectedly selected' >&2
    exit 1
fi

echo 'PASS: Android device ABI selection'
