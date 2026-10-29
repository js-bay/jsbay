#!/usr/bin/env bash
# Per-workload warmup and measurement counts describe the work actually timed.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-benchmark-operation-metadata.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cd "$root"
make benchmark-interop RUNNER=c_abi >"$tmp/record.json" 2>"$tmp/record.err"
jq -e '
  .runner_kind == "c_abi" and
  ([.operations[].name] | sort == ["buffer_copy", "eval_compute", "host_callback", "lifecycle", "text_json"]) and
  all(.operations[];
    .warmup_iterations == 100 and
    (.measured_iterations | type == "number" and . > 0) and
    (.operations | type == "number" and . > 0) and
    (.elapsed_ns | type == "number" and . > 0) and
    (.ns_per_op | type == "number" and . > 0) and
    (if .name == "lifecycle" then .measured_iterations == 100 and .operations == 100
     else .measured_iterations == 1000 and .operations == 1000 end)
  )
' "$tmp/record.json" >/dev/null
