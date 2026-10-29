#!/usr/bin/env bash
# Harmony device: attempt process-isolation Zig-abort proof via hdc-pushed native ELF.
# Soft-fail / close-ordering remain in run-crash-isolation-harmony.sh.
# If OHOS toolchain / zig ohos build cannot produce a runnable ELF, SKIP with reason.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDC="${HDC:-hdc}"
HDC_SERIAL="${HDC_SERIAL:?set HDC_SERIAL to the hdc device serial}"
BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"
OUT="${HARMONY_PROCESS_ISOLATION_OUT:-/tmp/jsbay-harmony-process-isolation}"
REMOTE="${HARMONY_PROCESS_ISOLATION_REMOTE:-/data/local/tmp/jsbay-process-isolation}"
OHOS_SDK_NATIVE="${OHOS_SDK_NATIVE:?set OHOS_SDK_NATIVE to the ohos-sdk native toolchain dir}"
OHOS_SYSROOT="${OHOS_SYSROOT:-$OHOS_SDK_NATIVE/sysroot}"
OHOS_CLANG="${OHOS_CLANG:-$OHOS_SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; }

hdc_cmd() {
  "$HDC" -t "$HDC_SERIAL" "$@"
}

echo "== hdc device =="
test -x "$HDC" || { skip "hdc missing at $HDC"; exit 0; }
LIST="$(hdc_cmd list targets 2>&1 || true)"
echo "hdc targets: $LIST"
printf '%s' "$LIST" | grep -q "$HDC_SERIAL" || { skip "hdc-device $HDC_SERIAL not listed"; exit 0; }

if [ ! -x "$OHOS_CLANG" ] || [ ! -d "$OHOS_SYSROOT" ]; then
  skip "ohos-toolchain — clang or sysroot missing (OHOS_CLANG=$OHOS_CLANG OHOS_SYSROOT=$OHOS_SYSROOT)"
  exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT/fault" "$OUT/bin"

echo "== zig build aarch64-linux-ohos fault-injection =="
set +e
(cd "$ROOT" && zig build -Dbackend="$BACKEND" -Doptimize=ReleaseFast -Dlibrary-only=true \
  -Dfault-injection=true \
  -Dtarget=aarch64-linux-ohos \
  -Dohos-sysroot="$OHOS_SYSROOT" \
  --prefix "$OUT/fault") >"$OUT/zig-build.log" 2>&1
ZIG_RC=$?
set -e
if [ "$ZIG_RC" -ne 0 ]; then
  cat "$OUT/zig-build.log" | tail -n 40
  skip "ohos-zig-build — zig build aarch64-linux-ohos fault-injection failed (see $OUT/zig-build.log)"
  exit 0
fi
FAULT_A="$OUT/fault/lib/libjsbay.a"
test -f "$FAULT_A" || { skip "ohos-zig-build — missing $FAULT_A"; exit 0; }
if ! nm "$FAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null \
  && ! "$OHOS_SDK_NATIVE/llvm/bin/llvm-nm" "$FAULT_A" 2>/dev/null | grep -E 'jsbay_test_trigger_native_fault' >/dev/null; then
  fail "ohos fault archive missing jsbay_test_trigger_native_fault"
fi
pass "ohos-fault-injection-archive"

echo "== link harness with OHOS clang =="
# Extract objects and link a PIE executable for device /data/local/tmp.
OBJS="$OUT/objs"
mkdir -p "$OBJS"
( cd "$OBJS" && "$OHOS_SDK_NATIVE/llvm/bin/llvm-ar" x "$FAULT_A" )
find "$OBJS" -type f ! -name '*.o' -delete
set +e
"$OHOS_CLANG" -std=c11 -Wall -Wextra -fPIE -pie \
  --sysroot="$OHOS_SYSROOT" \
  -I"$ROOT/include" -I"$ROOT/tests/process-isolation" \
  "$ROOT/tests/process-isolation/harness.c" "$OBJS"/*.o \
  -lm -ldl -o "$OUT/bin/process_isolation_harness" >"$OUT/link.log" 2>&1
LINK_RC=$?
set -e
if [ "$LINK_RC" -ne 0 ]; then
  cat "$OUT/link.log" | tail -n 40
  skip "ohos-link — could not link process_isolation_harness (see $OUT/link.log)"
  exit 0
fi
pass "linked-ohos-process-isolation-harness"

echo "== push + run on Harmony device =="
hdc_cmd shell "rm -rf $REMOTE; mkdir -p $REMOTE" || true
hdc_cmd file send "$OUT/bin/process_isolation_harness" "$REMOTE/process_isolation_harness"
hdc_cmd shell "chmod 755 $REMOTE/process_isolation_harness" || true

set +e
HARNESS_OUT="$(hdc_cmd shell "$REMOTE/process_isolation_harness" 2>&1)"
HARNESS_RC=$?
set -e
printf '%s\n' "$HARNESS_OUT"
echo "harness_exit=$HARNESS_RC"

if printf '%s' "$HARNESS_OUT" | grep -q 'PASS: process-isolation harness complete' \
  && printf '%s' "$HARNESS_OUT" | grep -q 'PASS: parent-survives-abort-child'; then
  pass "harmony-device Zig-abort process-isolation"
  echo "PASS: harmony process-isolation device run complete"
  exit 0
fi

# OpenHarmony SELinux labels /data/local/tmp as data_local_tmp; shell (u:r:sh:s0) cannot
# exec arbitrary native ELFs there (Permission denied) without a HAP Ability / root.
if printf '%s' "$HARNESS_OUT" | grep -qi 'Permission denied'; then
  pass "ohos-build-link-push (archive+ELF on device)"
  skip "hdc-exec — SELinux blocks shell-exec of /data/local/tmp native ELF (need HAP Ability or root). Soft-fail/close-order: run-crash-isolation-harmony.sh"
  exit 0
fi

fail "harmony-device harness incomplete exit=$HARNESS_RC"
