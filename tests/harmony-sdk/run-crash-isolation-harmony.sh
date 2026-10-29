#!/usr/bin/env bash
# Harmony soft-failure / close-ordering / crash-isolation harness.
#
# Layers:
#   1) Node N-API host (same jsbay_harmony.cpp) — Linux/macOS box/CI
#   2) Device ArkTS via hdc — DevEco HAP + physical device
#
# Host anti-pattern under test: post destroy/close on a Worker then IMMEDIATELY
# terminate without awaiting native destroy (orphan engine thread / TSFN into a
# dead env). jsbay uses sync closeEngine + envCleanup; host misuse is still probed.
#
# Device:
#   HDC=/path/to/hdc HDC_SERIAL=<device-serial> \
#   JSBAY_LIBRARY=/path/to/host/libjsbay.a \
#   bash tests/harmony-sdk/run-crash-isolation-harmony.sh
#
# Node only:
#   JSBAY_LIBRARY=... NODE_INCLUDE=... bash tests/harmony-sdk/run-crash-isolation-harmony.sh --node-only
# If system c++ is missing: printf '#!/bin/bash\nexec zig c++ "$@"\n' >/tmp/zig-cxx.sh && chmod +x /tmp/zig-cxx.sh
#   CXX=/tmp/zig-cxx.sh JSBAY_LIBRARY=... NODE_INCLUDE=... bash tests/harmony-sdk/run-crash-isolation-harmony.sh --node-only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE_BIN="${NODE_BIN:-node}"
HDC="${HDC:-hdc}"
HDC_SERIAL="${HDC_SERIAL:-}"
MODE="${1:-all}"
ADDON_DIR="${JSBAY_NAPI_HOST_DIR:-/tmp/jsbay-normalization/napi-host}"
ADDON="$ADDON_DIR/jsbay_harmony.node"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; }

build_node_addon() {
  : "${JSBAY_LIBRARY:?set JSBAY_LIBRARY to a host-platform libjsbay.a}"
  HARMONY_SKIP_NATIVE_CONSUMER=1 \
    JSBAY_LIBRARY="$JSBAY_LIBRARY" \
    JSBAY_NAPI_HOST_DIR="$ADDON_DIR" \
    NODE_INCLUDE="${NODE_INCLUDE:-}" \
    bash "$ROOT/tests/harmony-sdk/run_native_consumer.sh"
  test -f "$ADDON" || fail "node addon missing at $ADDON"
}

run_node_host() {
  echo "== Node N-API crash-isolation (jsbay_harmony bridge) =="
  build_node_addon
  set +e
  local out rc
  out="$(JSBAY_HARMONY_NODE="$ADDON" "$NODE_BIN" --expose-gc \
    "$ROOT/tests/harmony-sdk/crash_isolation_consumer.cjs" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "node_exit=$rc"
  if [[ "$rc" -ne 0 ]] || ! printf '%s' "$out" | grep -q 'PASS: harmony crash-isolation harness complete'; then
    fail "node crash-isolation harness"
  fi
  pass "node crash-isolation harness"
}

run_device_hdc() {
  echo "== Device ArkTS crash-isolation via hdc =="
  if [[ ! -x "$HDC" ]] && ! command -v "$HDC" >/dev/null 2>&1; then
    skip "hdc-device — hdc not found (set HDC=.../toolchains/hdc)"
    return 0
  fi
  local hdc_cmd=("$HDC")
  if [[ -n "$HDC_SERIAL" ]]; then
    hdc_cmd+=(-t "$HDC_SERIAL")
  fi
  local list
  set +e
  list="$("${hdc_cmd[@]}" list targets 2>&1)"
  set -e
  echo "hdc targets: $list"
  if ! printf '%s' "$list" | grep -Eq '[0-9A-Za-z]{4,}'; then
    skip "hdc-device — no device (expected ${HDC_SERIAL:-any})"
    return 0
  fi

  # Sources for DevEco packaging / build_har typecheck:
  #   tests/harmony-sdk/CrashIsolation.ets
  #   tests/harmony-sdk/CrashIsolationWorker.ets
  # Typecheck with HAR:
  #   HARMONY_EXTRA_ARKTS_FIXTURE=$ROOT/tests/harmony-sdk/CrashIsolation.ets \
  #     bash tests/harmony-sdk/build_har.sh
  # Also copy CrashIsolationWorker.ets into the Ability Worker path the HAP loads.
  if [[ -z "${HARMONY_CRASH_HAP:-}" ]]; then
    skip "hdc-device-execute — set HARMONY_CRASH_HAP once an Ability calls runCrashIsolation('./CrashIsolationWorker.ets'). Grep hilog: PASS:|FAIL:|SKIP:|Tags.JS_ENGINE|Engine.close|ww onerror|destroyEngine|flushBarrier"
    echo "HINT: close order = cancel loop → close values → engine.close → only then ThreadWorker.terminate"
    echo "HINT: never terminate Worker before native destroy completes (host anti-pattern)"
    set +e
    "${hdc_cmd[@]}" shell "hilog -x 2>/dev/null | grep -E 'PASS:|FAIL:|SKIP:|Tags.JS_ENGINE|Engine.close|ww onerror|destroyEngine|flushBarrier' | tail -n 40"
    set -e
    return 0
  fi

  echo "Installing/running $HARMONY_CRASH_HAP (caller-provided)…"
  set +e
  "${hdc_cmd[@]}" install -r "$HARMONY_CRASH_HAP"
  "${hdc_cmd[@]}" shell "hilog -x 2>/dev/null | grep -E 'PASS:|FAIL:|SKIP:|Tags.JS_ENGINE|Engine.close|ww onerror|destroyEngine' | tail -n 80"
  set -e
  pass "hdc-device (check hilog PASS lines from Ability)"
}

case "$MODE" in
  --node-only|node|node-only) run_node_host ;;
  --device-only|device|device-only) run_device_hdc ;;
  all|"") run_node_host; run_device_hdc ;;
  *) echo "usage: $0 [--node-only|--device-only]" >&2; exit 2 ;;
esac

echo "PASS: harmony crash-isolation runner finished"
