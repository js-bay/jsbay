#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo 'Usage: zig-libraries-coverage.sh <output-directory>' >&2
    exit 2
fi

root="$(git rev-parse --show-toplevel)"
output="$1"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
if [ -e "$output/zig-libraries-coverage.cobertura.xml" ]; then
    echo "Library coverage output already exists: $output/zig-libraries-coverage.cobertura.xml" >&2
    exit 2
fi
if [ "$(kcov --version)" != 'kcov 43' ]; then
    echo 'kcov 43 is required for comparable coverage reports' >&2
    exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-libraries-coverage.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

cd "$root"
if ! zig build --verbose test-packages --cache-dir "$work/zig-cache" > "$work/build.log" 2>&1; then
    cat "$work/build.log" >&2
    exit 2
fi
if ! node scripts/quality/zig-package-coverage-targets.mjs "$work/build.log" "$work/zig-cache" > "$work/binaries"; then
    cat "$work/build.log" >&2
    exit 2
fi

binaries=()
while IFS= read -r binary; do
    binaries+=("$binary")
done < "$work/binaries"

coverage_directories=()
test_sources=()
while IFS= read -r source; do
    case "${source##*/}" in
        test*.zig|*_tests.zig) test_sources+=("$root/$source") ;;
    esac
done < <(git ls-files 'libs/**/*.zig')
exclude_paths="$(IFS=,; printf '%s' "${test_sources[*]}")"
for index in "${!binaries[@]}"; do
    coverage_directory="$work/kcov/$index"
    mkdir -p "$coverage_directory"
    if ! kcov --include-path="$root/libs/" --exclude-path="$exclude_paths" "$coverage_directory" "${binaries[$index]}" > "$work/kcov-$index.log" 2>&1; then
        cat "$work/kcov-$index.log" >&2
        exit 2
    fi
    reports=("$coverage_directory"/test.*/cobertura.xml)
    if [ "${#reports[@]}" -ne 1 ] || [ ! -s "${reports[0]}" ]; then
        echo "Expected one non-empty package coverage report for ${binaries[$index]}" >&2
        exit 2
    fi
    coverage_directories+=("$coverage_directory")
done

if ! kcov --merge "$work/merged" "${coverage_directories[@]}" > "$work/merge.log" 2>&1; then
    cat "$work/merge.log" >&2
    exit 2
fi
report="$work/merged/kcov-merged/cobertura.xml"
filtered_report="$work/merged/zig-libraries-coverage.cobertura.xml"
if [ ! -s "$report" ] || ! node scripts/quality/zig-inline-test-coverage.mjs < "$report" > "$filtered_report"; then
    cat "$work/merge.log" >&2
    echo 'Failed to exclude inline Zig test declarations from the library coverage report' >&2
    exit 2
fi
if ! node scripts/quality/zig-coverage-report.mjs < "$filtered_report" || ! node scripts/quality/zig-libraries-coverage-report.mjs < "$filtered_report"; then
    cat "$work/merge.log" >&2
    echo 'The merged Zig library coverage report is missing or invalid' >&2
    exit 2
fi
cp "$filtered_report" "$output/zig-libraries-coverage.cobertura.xml"
cat "$work/merge.log" >&2
echo "Collected Zig library coverage from ${#binaries[@]} test targets."
