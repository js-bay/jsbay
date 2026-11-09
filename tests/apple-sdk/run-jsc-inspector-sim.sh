#!/usr/bin/env bash
set -euo pipefail

# Usage: JSBAY_IOS_SIM_UDID=<booted simulator> bash tests/apple-sdk/run-jsc-inspector-sim.sh <jsc-safari-demo>
# The caller owns the simulator. The Python driver starts and stops only its demo process.

root="$(cd "$(dirname "$0")/../.." && pwd)"
binary="${1:?usage: run-jsc-inspector-sim.sh <jsc-safari-demo>}"
simulator="${JSBAY_IOS_SIM_UDID:?set JSBAY_IOS_SIM_UDID to a booted simulator}"
application_name="$(basename "$binary")"
codesign -s - --force "$binary" >/dev/null
python3 "$root/tests/inspector/jsc_driver.py" --simulator "$simulator" --binary "$binary" --application-name "$application_name"
