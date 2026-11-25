#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo 'Usage: zig-jsc-coverage.sh <output-directory>' >&2
    exit 2
fi

root="$(git rev-parse --show-toplevel)"
output="$1"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
for file in jsc-coverage.cobertura.xml jsc-tests.json; do
    if [ -e "$output/$file" ]; then
        echo "Coverage output already exists: $output/$file" >&2
        exit 2
    fi
done
if [ "$(kcov --version)" != 'kcov 43' ]; then
    echo 'kcov 43 is required for comparable coverage reports' >&2
    exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-jsc-coverage.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

cd "$root"
if ! zig build test-compile -Dbackend=jsc -Dtest-llvm=true --cache-dir "$work/zig-cache" > "$work/build.log" 2>&1; then
    cat "$work/build.log" >&2
    exit 2
fi
binaries=("$work"/zig-cache/o/*/test)
if [ "${#binaries[@]}" -ne 1 ] || [ ! -x "${binaries[0]}" ]; then
    echo 'Expected exactly one compiled JSC engine test binary' >&2
    exit 2
fi

mkdir -p "$work/kcov"
if ! kcov --include-path="$root/src/" --exclude-path="$root/src/tests/" "$work/kcov" "${binaries[0]}" > "$work/tests.log" 2>&1; then
    cat "$work/tests.log" >&2
    exit 2
fi
if ! node scripts/quality/zig-coverage-summary.mjs < "$work/tests.log" > "$output/jsc-tests.json"; then
    cat "$work/tests.log" >&2
    exit 2
fi
reports=("$work/kcov"/test.*/cobertura.xml)
if [ "${#reports[@]}" -ne 1 ] || [ ! -s "${reports[0]}" ]; then
    echo 'Expected one non-empty JSC Cobertura report' >&2
    exit 2
fi
if ! node scripts/quality/zig-coverage-report.mjs < "${reports[0]}"; then
    cp "${reports[0]}" "$output/jsc-coverage-invalid.cobertura.xml"
    cat "$work/tests.log" >&2
    exit 2
fi
cp "${reports[0]}" "$output/jsc-coverage.cobertura.xml"
cat "$output/jsc-tests.json" >&2
