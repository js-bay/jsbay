#!/usr/bin/env bash
# Build signed HAP embedding jsbay CrashIsolation (+ multi-process ProbeAbility sketch).
# Product core: NEVER passes -Dfault-injection.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HAP_ROOT="$ROOT/tests/harmony-sdk/hap-crash-isolation"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:?set DEVECO_SDK_HOME}"
NODE_HOME="${NODE_HOME:?set NODE_HOME}"
HVIGORW="${HVIGORW:?set HVIGORW to hvigorw}"
OHPM="${OHPM:?set OHPM}"
NODE_PATH="${NODE_PATH:-}"
OHOS_SYSROOT="${OHOS_SYSROOT:?set OHOS_SYSROOT}"
CORE_PREFIX="${JSBAY_HAP_CORE_PREFIX:-/tmp/jsbay-hap-core}"
BACKEND="${QUICKJS_BACKEND:-quickjs_ng}"
export PATH="$NODE_HOME/bin:$PATH"
export DEVECO_SDK_HOME NODE_HOME NODE_PATH

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

test -x "$HVIGORW" || fail "HVIGORW missing: $HVIGORW"
test -x "$OHPM" || fail "OHPM missing: $OHPM"
test -d "$OHOS_SYSROOT" || fail "OHOS_SYSROOT missing: $OHOS_SYSROOT"

cp "$ROOT/tests/harmony-sdk/CrashIsolation.ets" "$HAP_ROOT/entry/src/main/ets/pages/CrashIsolation.ets"
cp "$ROOT/tests/harmony-sdk/CrashIsolationWorker.ets" "$HAP_ROOT/entry/src/main/ets/workers/CrashIsolationWorker.ets"

if [ "${SKIP_ZIG_CORE:-0}" != 1 ] || [ ! -f "$CORE_PREFIX/lib/libjsbay.a" ]; then
  echo "== zig build aarch64-linux-ohos library-only (NO fault-injection) =="
  mkdir -p "$CORE_PREFIX"
  (cd "$ROOT" && zig build -Dbackend="$BACKEND" -Dtarget=aarch64-linux-ohos \
    -Dohos-sysroot="$OHOS_SYSROOT" -Dlibrary-only=true -Doptimize=ReleaseFast \
    --prefix "$CORE_PREFIX")
fi
JSBAY_LIBRARY="$CORE_PREFIX/lib/libjsbay.a"
test -f "$JSBAY_LIBRARY" || fail "missing $JSBAY_LIBRARY"
if nm "$JSBAY_LIBRARY" | grep -q 'jsbay_test_trigger_native_fault'; then
  fail "product core must NOT export jsbay_test_trigger_native_fault"
fi
pass "ohos-product-core-no-fault-symbol"
export JSBAY_LIBRARY

echo "== assembleHar =="
rm -rf "$ROOT/sdk/harmony/.cxx" "$ROOT/sdk/harmony/oh_modules"
(cd "$ROOT/sdk/harmony" && "$OHPM" install --no-link)
rm -rf "$ROOT/tests/harmony-sdk/fixture/.hvigor" "$ROOT/tests/harmony-sdk/fixture/build" \
  "$ROOT/tests/harmony-sdk/fixture/oh_modules" "$ROOT/tests/harmony-sdk/fixture/node_modules"
(cd "$ROOT/tests/harmony-sdk/fixture" && "$HVIGORW" --mode module -p module=jsbay_harmony@default assembleHar)
HAR="$ROOT/sdk/harmony/build/default/outputs/default/jsbay_harmony.har"
test -f "$HAR" || fail "HAR missing after assembleHar"
pass "har-assembled"

echo "== ohpm install HAP entry deps (@js-bay/harmony HAR) =="
# Path from entry/ → ../../../../sdk/...
(cd "$HAP_ROOT/entry" && rm -rf oh_modules oh-package-lock.json5 && "$OHPM" install --no-link)

echo "== assembleHap (signed; bundleName must match debug profile: com.example.jsbay.eventwaiter) =="
(cd "$HAP_ROOT" && rm -rf .hvigor entry/build && "$HVIGORW" --mode module -p module=entry@default assembleHap)
SIGNED="$HAP_ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
test -f "$SIGNED" || fail "signed HAP missing"
pass "hap-signed $SIGNED"
echo "HAP_PATH=$SIGNED"
