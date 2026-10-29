#!/usr/bin/env bash
# Exercise the official Harmony formatter and its semantic/syntax failures.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
style=$root/scripts/quality/harmony-style.sh
temporary=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-style-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
source=$temporary/sdk/harmony/src/main/ets/Probe.ets
mkdir -p "$(dirname "$source")"
cp "$root/sdk/harmony/code-linter.json5" "$temporary/sdk/harmony/code-linter.json5"
expect_diagnostic() {
  mode=$1
  expected=$2
  set +e
  bash "$style" "$mode" --root "$temporary" > "$temporary/$mode.log" 2>&1
  result=$?
  set -e
  (( result == 1 )) || { cat "$temporary/$mode.log" >&2; echo "$mode must fail with a lint diagnostic, not tool failure (exit $result)" >&2; exit 1; }
  grep -Fq "$expected" "$temporary/$mode.log" || { cat "$temporary/$mode.log" >&2; echo "$mode did not report $expected" >&2; exit 1; }
}
expect_success() { bash "$style" "$1" --root "$temporary"; }
set +e
CODELINTER=/bin/false HARMONY_ETS_SDK=${HARMONY_ETS_SDK:-} bash "$style" check --root "$temporary" > "$temporary/missing-tool.log" 2>&1
tool_result=$?
set -e
(( tool_result == 2 )) || { cat "$temporary/missing-tool.log" >&2; echo "missing tool must be exit 2, got $tool_result" >&2; exit 1; }
printf '%s\n' 'export function answer(): number {return 42}' > "$source"
expect_diagnostic check 'diagnostics'
expect_success fix
formatted=$(cksum "$source")
grep -Fq '  return 42;' "$source" || { echo 'official fixer did not expand body' >&2; exit 1; }
expect_success check
expect_success fix
[[ $(cksum "$source") == "$formatted" ]] || { echo 'formatting is not idempotent' >&2; exit 1; }
printf '%s\n' 'export function same(value: number): boolean {' '  return value == 42;' '}' > "$source"
# Code Linter 1.0.0 suppresses its core eqeqeq detail, but still emits its diagnostic marker and exit 1; the exact status rejects missing-tool errors.
expect_diagnostic check 'additional diagnostics'
expect_diagnostic fix 'additional diagnostics'
printf '%s\n' 'export function broken(: number {' > "$source"
# The 1.0.0 parser also suppresses its parse detail; its distinct diagnostic marker remains required, while a broken/missing tool is asserted above as 2.
expect_diagnostic check 'additional diagnostics'
echo 'Harmony Code Linter consumer: PASS (style, semantic lint, syntax, fixes, idempotence)'
