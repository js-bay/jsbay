#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
jni_libs=${1:?usage: aar-backend-test.sh <jni-libs-directory> <gradle>}
gradle=${2:?Gradle executable required}
jni_libs=$(cd "$jni_libs" && pwd)
backend=$(cat "$jni_libs/../backend")
case "$backend" in
    quickjs) other_backend=quickjs_ng ;;
    quickjs_ng) other_backend=quickjs ;;
    *) echo "unsupported native backend: $backend" >&2; exit 2 ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-aar-backend.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp -R "$jni_libs" "$work/jniLibs"
printf '%s\n' "$backend" > "$work/backend"
aar="$root/sdk/android/jsbay/build/outputs/aar/jsbay-release.aar"

assemble() {
    "$gradle" --no-daemon --console=plain -p "$root/sdk/android" \
        -PjsbayJniLibs="$work/jniLibs" "$@" :jsbay:assembleRelease
}

assert_backend() {
    assemble "$@"
    printf '%s\n' "$backend" | cmp - <(unzip -p "$aar" assets/jsbay-backend.txt)
}

assert_mismatch() {
    local requested=$1
    if assemble "-PjsbayBackend=$requested" > "$work/mismatch.log" 2>&1; then
        echo "Gradle assembled an AAR with inconsistent backend metadata" >&2
        exit 1
    fi
    if ! grep -F "Android library backend does not match jsbayBackend=$requested" "$work/mismatch.log"; then
        cat "$work/mismatch.log" >&2
        exit 1
    fi
}

assert_backend
assert_mismatch "$other_backend"
assert_backend "-PjsbayBackend=$backend"
printf '%s\n' "$other_backend" > "$work/backend"
assert_mismatch "$backend"
printf '%s\n' "$backend" > "$work/backend"
assert_backend
printf 'PASS: Android AAR backend %s and incremental inputs\n' "$backend"
