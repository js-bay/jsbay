#!/usr/bin/env bash
# Black-box contract for production diagnostic footprint measurements.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
measure="$root/bench/measure-diagnostics.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-diagnostics-measure.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
out="$tmp/report"

[ -x "$measure" ] || { echo "missing measurement tool: $measure" >&2; exit 127; }
if ! "$measure" "$out" quickjs_ng >"$tmp/stdout" 2>"$tmp/stderr"; then
    cat "$tmp/stderr" >&2
    exit 1
fi
[ -s "$out/report.json" ] || { echo "missing report.json" >&2; exit 1; }

jq -e '
  .schema_version == 1 and .backend == "quickjs_ng" and
  (.modes | type == "array" and length == 3) and
  ([.modes[].name] | sort == ["full", "heap_off", "inspector_off"]) and
  all(.modes[];
    (.name | type == "string") and
    (.build.exit_code == 0) and
    (.consumer.exit_code == 0) and
    (.artifact.path | type == "string" and length > 0) and
    (.artifact.bytes | type == "number" and . > 0) and
    (.artifact.sha256 | test("^[a-f0-9]{64}$")) and
    (.consumer.path | type == "string" and length > 0) and
    (.consumer.bytes | type == "number" and . > 0) and
    (.consumer.sha256 | test("^[a-f0-9]{64}$")) and
    (.exports | type == "array" and length > 0 and all(.[]; type == "string")) and
    (.runtime_benchmark | type == "object") and
    (.runtime_benchmark.runner_kind == "c_abi") and
    (.runtime_benchmark.language == "c_abi") and
    (.runtime_benchmark.warmup_iterations == 100) and
    (.runtime_benchmark.measured_iterations == 1000) and
    (.runtime_benchmark.payload_bytes == 4096) and
    (.runtime_benchmark.operations | type == "array" and length == 5) and
    ([.runtime_benchmark.operations[].name] | sort == ["buffer_copy", "eval_compute", "host_callback", "lifecycle", "text_json"]) and
    all(.runtime_benchmark.operations[];
      .status == "ok" and
      (.warmup_iterations == 100) and
      (.measured_iterations | type == "number" and . > 0) and
      (.operations | type == "number" and . > 0) and
      (.elapsed_ns | type == "number" and . > 0) and
      (.ns_per_op | type == "number" and . > 0) and
      (if .name == "lifecycle" then .measured_iterations == 100 and .operations == 100
       else .measured_iterations == 1000 and .operations == 1000 end)
    )
  ) and
  ([.modes[].exports] | .[0] == .[1] and .[1] == .[2]) and
  (.modes[] | select(.name == "full") | .inspector_start == "ok" and .heap_snapshot == "partial") and
  (.modes[] | select(.name == "heap_off") | .inspector_start == "ok" and .heap_snapshot == "unsupported") and
  (.modes[] | select(.name == "inspector_off") | .inspector_start == "unsupported" and .heap_snapshot == "unsupported")
' "$out/report.json" >/dev/null

# The public headers define the ABI. Do not duplicate that set as a numeric baseline here: each diagnostic mode must export exactly those symbols, with no duplicates, omissions, or private additions.
zig build --build-file "$root/build.zig" tool -- check-diagnostic-exports "$out/report.json"

# A real toolchain failure must make the tool fail and must not publish a report. ZIG is an ordinary external dependency override, not a test hook.
if ZIG=/bin/false "$measure" "$tmp/forced-failure" quickjs_ng >"$tmp/failure.stdout" 2>"$tmp/failure.stderr"; then
    echo "forced measurement build failure unexpectedly succeeded" >&2
    exit 1
fi
[ ! -e "$tmp/forced-failure/report.json" ] || { echo "failed measurement published report.json" >&2; exit 1; }

# Refuse a nonempty destination so a failed rerun cannot be confused with an old successful report or silently overwrite a user's evidence.
mkdir "$tmp/stale-output"
printf '%s\n' stale >"$tmp/stale-output/report.json"
if "$measure" "$tmp/stale-output" quickjs_ng >"$tmp/stale.stdout" 2>"$tmp/stale.stderr"; then
    echo "measurement accepted a stale destination" >&2
    exit 1
fi
[ "$(cat "$tmp/stale-output/report.json")" = stale ] || { echo "measurement overwrote stale evidence" >&2; exit 1; }
