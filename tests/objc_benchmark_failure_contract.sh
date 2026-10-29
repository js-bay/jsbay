#!/usr/bin/env bash
# Objective-C must reject invalid SDK return values even when NSError is nil.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
if [ "$(uname -s)" != Darwin ]; then exit 0; fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-objc-benchmark-failure.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if ! bash "$root/bench/interop/run-apple.sh" objc jsc >"$tmp/baseline.out" 2>"$tmp/baseline.err"; then
    cat "$tmp/baseline.err" >&2
    exit 1
fi
[ -s "$tmp/baseline.out" ] || { echo "Objective-C benchmark baseline emitted no measurements" >&2; exit 1; }

for fault in empty_json wrong_buffer; do
    if JSBAY_INTEROP_FAULT="$fault" bash "$root/bench/interop/run-apple.sh" objc jsc >"$tmp/$fault.out" 2>"$tmp/$fault.err"; then
        echo "Objective-C benchmark accepted $fault with nil NSError" >&2
        exit 1
    fi
    [ ! -s "$tmp/$fault.out" ] || { echo "Objective-C benchmark printed measurements after $fault" >&2; exit 1; }
done
