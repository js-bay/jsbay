#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo 'Usage: zig-coverage.sh <output-directory>' >&2
    exit 2
fi
root="$(git rev-parse --show-toplevel)"
output="$1"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
for file in coverage.cobertura.xml coverage-invalid.cobertura.xml coverage-tests.json pawl.coverage.yaml; do
    if [ -e "$output/$file" ]; then
        echo "Coverage output already exists: $output/$file" >&2
        exit 2
    fi
done
if [ "$(kcov --version)" != 'kcov 43' ]; then
    echo 'kcov 43 is required for comparable coverage reports' >&2
    exit 2
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-coverage.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

cd "$root"
zig build test-compile -Dbackend=quickjs_ng --cache-dir "$work/zig-cache"
shopt -s nullglob
binaries=("$work"/zig-cache/o/*/test)
if [ "${#binaries[@]}" -ne 1 ] || [ ! -x "${binaries[0]}" ]; then
    echo 'Expected exactly one compiled engine test binary' >&2
    exit 2
fi
if ! kcov --include-path="$root/src/" --exclude-path="$root/src/tests/" "$work/kcov" "${binaries[0]}" 2>&1 | tee "$work/tests.log" >&2; then
    exit 2
fi
if ! node scripts/quality/zig-coverage-summary.mjs < "$work/tests.log" > "$work/tests.json"; then
    exit 2
fi
report="$work/kcov/test/cobertura.xml"
test -s "$report"
if ! node scripts/quality/zig-coverage-report.mjs < "$report"; then
    cp "$report" "$output/coverage-invalid.cobertura.xml"
    if command -v readelf >/dev/null 2>&1; then
        readelf --debug-dump=rawline "${binaries[0]}" > "$work/debug-lines.txt" 2>&1 || true
        awk 'NR <= 80 || (/\.zig/ && count++ < 40)' "$work/debug-lines.txt" > "$output/debug-lines-sample.txt"
        cat "$output/debug-lines-sample.txt" >&2
    fi
    exit 2
fi
cp "$report" "$output/coverage.cobertura.xml"
cp "$work/tests.json" "$output/coverage-tests.json"
cp pawl.coverage.yaml "$output/pawl.coverage.yaml"
cat "$output/coverage-tests.json" >&2
"${PAWL:-pawl}" measure -c "$output/pawl.coverage.yaml"
