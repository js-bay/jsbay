#!/bin/sh
# Run against the fully patched NG source directory produced by the build.
set -eu
src=${1:?usage: quickjs_ng_dispatch_contract.sh PATCHED_QUICKJS_NG_DIR}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$src" in /*) ;; *) src="$(pwd)/$src" ;; esac
out=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-ng-dispatch.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
for mode in direct switch; do
    extra=
    if [ "$mode" = switch ]; then extra=-DEMSCRIPTEN; fi
    "${CC:-cc}" -O2 -DJSBAY_INSPECTOR=1 -DJSBAY_DISPATCH_PROBE=1 \
        -DJSBAY_TEST_INCLUDE_QUICKJS_C=1 \
        -DJSBAY_HEAP_SNAPSHOT=0 $extra -I"$src" \
        "$src/dtoa.c" "$src/libregexp.c" "$src/libunicode.c" \
        "$root/tests/quickjs_ng_dispatch_consumer.c" -lm -o "$out/$mode"
    "$out/$mode"
done
