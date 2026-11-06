#!/usr/bin/env bash
set -euo pipefail
# Debugger benchmark output contract.

root=$(cd "$(dirname "$0")/.." && pwd)
tool="$root/bench/measure-debugger.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-debugger-benchmark.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$tool" "$tmp/report" quickjs_ng
jq -e '
  . as $report | .schema_version == 1 and .backend == "quickjs_ng" and .optimize == "ReleaseFast" and
  .workload_calls == 10 and .warmup_calls == 2 and .inner_loop_iterations == 1000 and
  .sample_order == ["cold", "enabled", "unmatched", "conditional"] and
  .samples_per_state == 5 and
  (.benchmark_source_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
  (.engine_source_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
  (.driver_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
  has("source_commit") and (.source_commit == null or (.source_commit | type == "string" and test("^[a-f0-9]{40}$"))) and
  has("source_dirty") and (.source_dirty == null or (.source_dirty | type == "boolean")) and
  (.toolchain | type == "string" and length > 0) and (.cc_version | type == "string" and length > 0) and
  (.host | type == "object" and (.platform | type == "string" and length > 0) and (.arch | type == "string" and length > 0) and (.node | type == "string" and test("^v[0-9]+\\."))) and
  (.artifact | type == "object" and (.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and (.bytes | type == "number" and . > 0 and floor == .)) and
  ([.states[].name] | sort == ["cold", "conditional", "enabled", "unmatched"]) and
  all(.states[]; (.samples_ns | type == "array" and length == $report.samples_per_state and all(.[]; type == "number" and . > 0)) and (.median_ns | type == "number" and . > 0) and (.relative_to_cold | type == "number" and . > 0)) and
  (.states[] | select(.name == "unmatched") | .resolved_locations > 0) and
  (.states[] | select(.name == "conditional") | .condition_hits == 12000 * $report.samples_per_state) and
  all(.states[] | select(.name != "conditional"); .condition_hits == 0)
' "$tmp/report/report.json" >/dev/null

if ZIG=/bin/false "$tool" "$tmp/build-failure" quickjs_ng >"$tmp/build-failure.stdout" 2>"$tmp/build-failure.stderr"; then
    echo "forced build failure unexpectedly succeeded" >&2
    exit 1
fi
[ ! -e "$tmp/build-failure/report.json" ] || { echo "failed build published report" >&2; exit 1; }
grep -q '^EXIT=[1-9]' "$tmp/build-failure/work/build.log"

mkdir "$tmp/stale-output"
printf '%s\n' stale >"$tmp/stale-output/report.json"
if "$tool" "$tmp/stale-output" quickjs_ng >"$tmp/stale.stdout" 2>"$tmp/stale.stderr"; then
    echo "measurement accepted an existing output directory" >&2
    exit 1
fi
[ "$(cat "$tmp/stale-output/report.json")" = stale ] || { echo "measurement overwrote existing report" >&2; exit 1; }

metadata_env=(JSBAY_DEBUGGER_SOURCE_SHA=$(printf '0%.0s' {1..64}) JSBAY_DEBUGGER_ENGINE_SOURCE_SHA=$(printf '1%.0s' {1..64}) JSBAY_DEBUGGER_DRIVER_SHA=$(printf '2%.0s' {1..64}) JSBAY_DEBUGGER_TOOLCHAIN=test-toolchain JSBAY_DEBUGGER_CC_VERSION=test-cc JSBAY_DEBUGGER_SOURCE_COMMIT=null JSBAY_DEBUGGER_SOURCE_DIRTY=false)
set +e
env -u JSBAY_DEBUGGER_SOURCE_SHA node "$root/bench/debugger_benchmark_driver.mjs" --bin /definitely-missing-debugger-consumer --out "$tmp/missing-metadata.json" --samples 1 >"$tmp/missing-metadata.stdout" 2>"$tmp/missing-metadata.stderr"
status=$?
set -e
[ "$status" -eq 64 ] || { echo "missing metadata did not fail before spawning" >&2; exit 1; }
grep -q 'Invalid debugger benchmark metadata: JSBAY_DEBUGGER_SOURCE_SHA' "$tmp/missing-metadata.stderr"

set +e
env "${metadata_env[@]}" JSBAY_DEBUGGER_ENGINE_SOURCE_SHA=not-a-hash node "$root/bench/debugger_benchmark_driver.mjs" --bin /definitely-missing-debugger-consumer --out "$tmp/malformed-metadata.json" --samples 1 >"$tmp/malformed-metadata.stdout" 2>"$tmp/malformed-metadata.stderr"
status=$?
set -e
[ "$status" -eq 64 ] || { echo "malformed metadata did not fail before spawning" >&2; exit 1; }
grep -q 'Invalid debugger benchmark metadata: JSBAY_DEBUGGER_ENGINE_SOURCE_SHA' "$tmp/malformed-metadata.stderr"

set +e
env "${metadata_env[@]}" node "$root/bench/debugger_benchmark_driver.mjs" --bin "$root/tests/debugger_benchmark_hang_consumer.sh" --out "$tmp/hang-report.json" --samples 1 --timeout-ms 20 >"$tmp/hang.stdout" 2>"$tmp/hang.stderr"
status=$?
set -e
[ "$status" -ne 0 ] || { echo "hung consumer unexpectedly succeeded" >&2; exit 1; }
[ ! -e "$tmp/hang-report.json" ] || { echo "hung consumer published report" >&2; exit 1; }
grep -q 'after timeout' "$tmp/hang.stderr"

node "$root/tests/debugger_benchmark_http_failure.mjs" "$root"
node "$root/tests/debugger_benchmark_cleanup_failure.mjs" "$root"
node "$root/tests/debugger_benchmark_protocol_failures.mjs" "$root"
