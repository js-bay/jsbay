#!/usr/bin/env bash
set -euo pipefail

# Usage: JSBAY_IOS_SIM_UDID=<booted simulator> bash tests/apple-sdk/run-jsc-bridge-sim.sh <jsc-safari-demo> [extra e2e args]
# The caller owns the simulator. This script starts and stops only its own demo and bridge processes.
# The demo binary must be built for the simulator; the bridge runs on the host and exposes CDP on loopback.
# Steps listed in jsc_unsupported_steps describe CDP behavior JSC cannot produce and are skipped.

root="$(cd "$(dirname "$0")/../.." && pwd)"
binary="${1:?usage: run-jsc-bridge-sim.sh <jsc-safari-demo> [extra e2e args]}"
shift
simulator="${JSBAY_IOS_SIM_UDID:?set JSBAY_IOS_SIM_UDID to a booted simulator}"
bridge="${JSBAY_INSPECTOR_BRIDGE:-$root/devtools/jsc-inspector-bridge/zig-out/bin/jsbay-inspector-bridge}"
port="${JSBAY_INSPECTOR_BRIDGE_PORT:-9333}"
application_name="$(basename "$binary")"

if [[ ! -x "$bridge" ]]; then
  (cd "$root/devtools/jsc-inspector-bridge" && zig build)
fi

# A JavaScript callback that a native frame called is the only frame on the paused stack, so a stepOut has no JavaScript caller to stop in: the relay reports Debugger.resumed and the next pause, if any, is a fresh breakpoint hit.

# Console API calls stay with the host console client, so the relay never reports console arguments.
jsc_unsupported_steps=(
  native-callback-step-out
  native-runtime
)

demo_log="$(mktemp -t jsbay-jsc-demo)"
bridge_log="$(mktemp -t jsbay-jsc-bridge)"
demo_pid=""
bridge_pid=""
cleanup() {
  if [[ -n "$bridge_pid" ]]; then kill -9 "$bridge_pid" 2>/dev/null || true; fi
  if [[ -n "$demo_pid" ]]; then kill -9 "$demo_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

codesign -s - --force "$binary" >/dev/null
xcrun simctl spawn "$simulator" "$binary" >"$demo_log" 2>&1 &
for _ in $(seq 1 200); do
  demo_pid="$(sed -n 's/^STARTED \([0-9]*\).*/\1/p' "$demo_log" | head -1)"
  if [[ -n "$demo_pid" ]] && grep -q '^READY' "$demo_log"; then break; fi
  sleep 0.1
done
if [[ -z "$demo_pid" ]]; then
  echo "demo did not start; log $demo_log" >&2
  cat "$demo_log" >&2
  exit 1
fi

# The socket path appears in the simulator environment once webinspectord runs, which happens on demand.
socket="$(xcrun simctl spawn "$simulator" launchctl getenv RWI_LISTEN_SOCKET || true)"
if [[ -z "$socket" ]]; then
  xcrun simctl spawn "$simulator" launchctl kickstart user/foreground/com.apple.webinspectord >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    socket="$(xcrun simctl spawn "$simulator" launchctl getenv RWI_LISTEN_SOCKET || true)"
    if [[ -n "$socket" ]]; then break; fi
    sleep 0.2
  done
fi
if [[ -z "$socket" ]]; then
  echo "webinspectord socket is unset; is the simulator booted?" >&2
  exit 1
fi

start_bridge() {
  : >"$bridge_log"
  "$bridge" --socket "$socket" --application "$application_name" --port "$port" >"$bridge_log" 2>&1 &
  bridge_pid=$!
  for _ in $(seq 1 200); do
    if grep -q '^CDP endpoint' "$bridge_log"; then return 0; fi
    if ! kill -0 "$bridge_pid" 2>/dev/null; then return 1; fi
    sleep 0.1
  done
  return 1
}

if ! start_bridge; then
  # A target killed without closing its inspector session can leave the relay without application records. Only that state justifies restarting the shared daemon, which drops every other inspector session in this simulator, so any other failure is reported as it is.
  if ! grep -qE 'error: (DiscoveryTimeout|DiscoveryFailed)' "$bridge_log"; then
    echo "bridge did not accept CDP connections; log $bridge_log" >&2
    cat "$bridge_log" >&2
    exit 1
  fi
  xcrun simctl spawn "$simulator" launchctl kickstart -k user/foreground/com.apple.webinspectord
  socket="$(xcrun simctl spawn "$simulator" launchctl getenv RWI_LISTEN_SOCKET)"
  sleep 1
  if ! start_bridge; then
    echo "bridge did not accept CDP connections after a relay restart; log $bridge_log" >&2
    cat "$bridge_log" >&2
    exit 1
  fi
fi

skip_args=()
for step in "${jsc_unsupported_steps[@]}"; do skip_args+=(--skip-step "$step"); done

status=0
node "$root/tests/inspector/e2e.cjs" --port "$port" --debugger-flow --native-debugger "${skip_args[@]}" "$@" || status=$?
if [[ "$status" -ne 0 ]]; then
  echo "demo log $demo_log" >&2
  echo "bridge log $bridge_log" >&2
  tail -20 "$demo_log" >&2
fi
exit "$status"
