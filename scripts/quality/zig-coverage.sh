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
for file in coverage.cobertura.xml coverage-invalid.cobertura.xml coverage-tests.json quickjs-tests.json pawl.coverage.yaml quickjs-coverage.cobertura.xml quickjs-ng-coverage.cobertura.xml quickjs-engines-coverage.cobertura.xml pawl.quickjs-engines-coverage.yaml quickjs-engines-coverage.json zig-coverage-inventory.json; do
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
backend_reports=()
for backend in quickjs quickjs_ng; do
    cache="$work/$backend-cache"
    log="$work/$backend-build.log"
    if ! zig build test-compile "-Dbackend=$backend" -Dtest-llvm=true --cache-dir "$cache" > "$log" 2>&1; then
        cat "$log" >&2
        exit 2
    fi
    binaries=("$cache"/o/*/test)
    if [ "${#binaries[@]}" -ne 1 ] || [ ! -x "${binaries[0]}" ]; then
        echo "Expected exactly one compiled $backend engine test binary" >&2
        exit 2
    fi

    coverage_directory="$work/$backend-kcov"
    mkdir -p "$coverage_directory"
    test_log="$work/$backend-tests.log"
    if ! kcov --include-path="$root/src/" --exclude-path="$root/src/tests/" "$coverage_directory" "${binaries[0]}" > "$test_log" 2>&1; then
        cat "$test_log" >&2
        exit 2
    fi
    summary="$work/$backend-tests.json"
    if ! node scripts/quality/zig-coverage-summary.mjs < "$test_log" > "$summary"; then
        cat "$test_log" >&2
        exit 2
    fi
    reports=("$coverage_directory"/test.*/cobertura.xml)
    if [ "${#reports[@]}" -ne 1 ] || [ ! -s "${reports[0]}" ]; then
        echo "Expected one non-empty $backend Cobertura report" >&2
        exit 2
    fi
    if ! node scripts/quality/zig-coverage-report.mjs < "${reports[0]}"; then
        cp "${reports[0]}" "$output/coverage-invalid.cobertura.xml"
        if command -v readelf >/dev/null 2>&1; then
            readelf --debug-dump=rawline "${binaries[0]}" > "$work/$backend-debug-lines.txt" 2>&1 || true
            awk 'NR <= 80 || (/\.zig/ && count++ < 40)' "$work/$backend-debug-lines.txt" > "$output/debug-lines-sample.txt"
        fi
        cat "$test_log" >&2
        exit 2
    fi
    backend_reports+=("${reports[0]}")
    if [ "$backend" = quickjs_ng ]; then
        cp "${reports[0]}" "$output/coverage.cobertura.xml"
        cp "$summary" "$output/coverage-tests.json"
    else
        cp "$summary" "$output/quickjs-tests.json"
    fi
    cat "$summary" >&2
done

quickjs_dir="$(dirname "${backend_reports[0]}")"
quickjs_ng_dir="$(dirname "${backend_reports[1]}")"
cp "${backend_reports[0]}" "$output/quickjs-coverage.cobertura.xml"
cp "${backend_reports[1]}" "$output/quickjs-ng-coverage.cobertura.xml"
if ! kcov --merge "$work/merged" "$quickjs_dir" "$quickjs_ng_dir" > "$work/merge.log" 2>&1; then
    cat "$work/merge.log" >&2
    exit 2
fi
merged_report="$work/merged/kcov-merged/cobertura.xml"
test -s "$merged_report"
if ! node scripts/quality/zig-coverage-report.mjs < "$merged_report"; then
    echo 'Merged backend coverage report is invalid' >&2
    cat "$work/merge.log" >&2
    exit 2
fi
if ! node scripts/quality/zig-coverage-merge.mjs "${backend_reports[0]}" "${backend_reports[1]}" "$merged_report" "$output/quickjs-engines-coverage.cobertura.xml" > "$output/quickjs-engines-coverage.json"; then
    cat "$work/merge.log" >&2
    exit 2
fi
cp pawl.coverage.yaml "$output/pawl.coverage.yaml"
cat > "$output/pawl.quickjs-engines-coverage.yaml" <<'EOF'
dimensions:
  - id: quickjs-engines-compiled-zig-line-coverage
    title: QuickJS and QuickJS-NG compiled Zig source line coverage
    direction: higher-is-better
    builtin: coverage
    options:
      file: quickjs-engines-coverage.cobertura.xml
      format: cobertura
      metric: lines
EOF
"${PAWL:-pawl}" measure -c "$output/pawl.coverage.yaml"
"${PAWL:-pawl}" measure -c "$output/pawl.quickjs-engines-coverage.yaml"
