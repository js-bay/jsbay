#!/bin/sh
# Run against the fully patched NG source directory produced by the build.
set -eu
src=${1:?usage: quickjs_ng_debug_eval_contract.sh PATCHED_QUICKJS_NG_DIR}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$src" in /*) ;; *) src="$(pwd)/$src" ;; esac
out=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-ng-debug-eval.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
"${CC:-cc}" -O2 -UNDEBUG -DJSBAY_INSPECTOR=1 -DJSBAY_HEAP_SNAPSHOT=0 \
    -DJSBAY_TEST_INCLUDE_QUICKJS_C=1 -I"$src" \
    "$src/dtoa.c" "$src/libregexp.c" "$src/libunicode.c" \
    "$root/tests/quickjs_ng_debug_eval_consumer.c" -lm -o "$out/debug-eval"
"$out/debug-eval"
