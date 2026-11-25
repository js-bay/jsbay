#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-apple-simulator-diagnostics.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

source "$ROOT/scripts/apple_simulator_diagnostics.sh"
build_script="$ROOT/build-apple.sh"
test "$(grep -Fc 'source "$SCRIPT_DIR/scripts/apple_simulator_diagnostics.sh"' "$build_script")" = 1
test "$(grep -Fc 'report_ios_simulator_failure "$sim_log" "$sim_rc"' "$build_script")" = 2

printf '%s\n' 'simulator launch failed: fixture diagnostic' > "$WORK/simulator.log"
diagnostic="$(report_ios_simulator_failure "$WORK/simulator.log" 1 2>&1)"
grep -Fq "status 1; log: $WORK/simulator.log" <<< "$diagnostic"
grep -Fq 'simulator launch failed: fixture diagnostic' <<< "$diagnostic"

diagnostic="$(report_ios_simulator_failure "$WORK/missing.log" 65 2>&1)"
grep -Fq 'status 65;' <<< "$diagnostic"
grep -Fq 'console log is empty or unavailable' <<< "$diagnostic"

echo 'PASS: Apple Simulator failures print captured console diagnostics'
