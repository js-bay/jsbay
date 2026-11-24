#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-runner-contract.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
RUNNER="${ANDROID_TEST_RUNNER:-$ROOT/scripts/android-unit-tests/android_test_runner.zig}"
cat > "$WORK/probe.zig" <<'EOF'
const std = @import("std");
test "clean pass" {}
test "logged success" { std.log.err("intentional fixture error", .{}); }
test "logged skip" { std.log.err("intentional skipped fixture error", .{}); return error.SkipZigTest; }
test "clean skip" { return error.SkipZigTest; }
EOF
zig test "$WORK/probe.zig" --test-runner "$RUNNER" --test-no-exec -femit-bin="$WORK/probe"
for mode in process isolate; do
    options=()
    if [[ "$mode" == isolate ]]; then options=(--isolate --timeout=5); fi
    for name in 'clean pass' 'clean skip' 'logged success' 'logged skip'; do
        set +e
        "$WORK/probe" "${options[@]}" "--test-filter=$name" > "$WORK/result.log" 2>&1
        status=$?
        set -e
        cat "$WORK/result.log"
        expected=0
        if [[ "$name" == logged* ]]; then expected=1; fi
        if [[ "$status" != "$expected" ]]; then
            echo "Unexpected runner status for $mode / $name: $status (expected $expected)" >&2
            exit 1
        fi
    done
done
echo 'PASS runner error-log contract in-process and isolated'
