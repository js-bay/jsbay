#!/usr/bin/env bash
# Run the engine's own upstream regression scripts (vendor/<engine>/tests) against the engine source tree as JS Bay builds it: same copy, same patch scripts, same patch order as build.zig. The upstream CLI binaries are built with the system C compiler, so no JS Bay glue is involved.
#
#   quickjs_ng  upstream `make test` = `run-test262 -c tests.conf`; each test file
#               is run through the same runner with `-f <file>`, because the
#               tests carry test262-style front matter (negative:, flags:).
#   quickjs     upstream `make test` = `qjs [args] tests/<file>.js`.
#
# Exit status: 0 only if at least one test ran and none failed or timed out.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
manifest="$root/tests/qjs-regression/manifest.txt"
engine=quickjs_ng
inspector=on
patched=1
gc_stress=0
overlay=
filter=
keep=
timeout_secs=60
while [ "$#" -gt 0 ]; do
    case "$1" in
        --engine) [ "$#" -ge 2 ] || exit 64; engine=$2; shift 2 ;;
        --inspector) [ "$#" -ge 2 ] || exit 64; inspector=$2; shift 2 ;;
        --overlay) [ "$#" -ge 2 ] || exit 64; overlay=$2; shift 2 ;;
        --filter) [ "$#" -ge 2 ] || exit 64; filter=$2; shift 2 ;;
        --keep) [ "$#" -ge 2 ] || exit 64; keep=$2; shift 2 ;;
        --timeout) [ "$#" -ge 2 ] || exit 64; timeout_secs=$2; shift 2 ;;
        --unpatched) patched=0; shift ;;
        --gc-stress) gc_stress=1; shift ;;
        -h|--help)
            cat <<'USAGE'
usage: run.sh [--engine quickjs_ng|quickjs] [--inspector on|off] [--unpatched]
              [--gc-stress] [--overlay DIR] [--filter REGEX] [--timeout SECS] [--keep DIR]

  --inspector   compile with JSBAY_INSPECTOR/JSBAY_HEAP_SNAPSHOT 1 (default) or 0
  --unpatched   pristine upstream tree, to tell a patch regression from an upstream failure
  --gc-stress   build with FORCE_GC_AT_MALLOC and honour upstream gc-stress-skip.txt
  --overlay     copy DIR/* over the tree's tests/ (to try a modified test)
  --filter      only run tests whose path matches the extended regex
  --keep        build in DIR and keep it instead of a deleted temp dir
USAGE
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
done
case "$engine" in quickjs_ng|quickjs) ;; *) echo "unsupported engine: $engine" >&2; exit 64 ;; esac
case "$inspector" in on|off) ;; *) echo "--inspector takes on|off" >&2; exit 64 ;; esac
case "$timeout_secs" in ''|*[!0-9]*) echo "--timeout takes whole seconds" >&2; exit 64 ;; esac
command -v perl >/dev/null || { echo "perl is required for the per-test timeout" >&2; exit 69; }

if [ -n "$keep" ]; then
    work=$keep
    mkdir -p "$work"
else
    work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-qjsreg.XXXXXX")
fi
cleanup() {
    local cleanup_status=$?
    [ -n "$keep" ] || rm -rf "$work"
    exit "$cleanup_status"
}
trap cleanup EXIT

# build.zig stays the authority for patch order; this list must match it.
if [ "$engine" = quickjs_ng ]; then
    src=$root/vendor/quickjs-ng
    patch_command=patch-quickjs-ng
    zig_fn=preparePatchedQuickJsNg
    patches=(quickjs-ng-debugger quickjs-ng-debugger-pause quickjs-ng-dataview-native
        quickjs-ng-optional-inspector quickjs-ng-heap-labels quickjs-ng-break-locations
        quickjs-ng-script-tags quickjs-ng-inspector-off)
else
    src=$root/vendor/quickjs
    patch_command=patch-quickjs
    zig_fn=preparePatchedQuickJs
    patches=(quickjs-finalizer quickjs-heap quickjs-async-stack quickjs-ubsan
        quickjs-array-identity quickjs-dataview-native quickjs-heap-labels
        quickjs-promise-then quickjs-inspector-off quickjs-transfer-neuter)
fi
[ -f "$src/quickjs.c" ] || { echo "engine source missing (submodule not checked out?): $src" >&2; exit 66; }

want=$(printf 'vendor/%s.patch\n' "${patches[@]}")
have=$(awk -v fn="fn $zig_fn(" 'index($0, fn) {on=1} on && /^}/ {exit} on' "$root/build.zig" |
    grep -o 'vendor/[A-Za-z0-9_.-]*\.patch' || true)
if [ "$want" != "$have" ]; then
    echo "patch list in this script differs from build.zig $zig_fn; update it to match." >&2
    printf 'script:\n%s\nbuild.zig:\n%s\n' "$want" "$have" >&2
    exit 70
fi

tree=$work/tree
mkdir -p "$tree"
if [ "$patched" = 1 ]; then
    patch_args=()
    for p in "${patches[@]}"; do patch_args+=("$root/vendor/$p.patch"); done
    zig build --build-file "$root/build.zig" tool -- "$patch_command" "$src" "$tree" "${patch_args[@]}" >"$work/patch.log" 2>&1 ||
        { cat "$work/patch.log" >&2; echo "applying patches failed" >&2; exit 1; }
else
    tar -C "$src" --exclude=.git -cf - . | tar -C "$tree" -xf -
fi
if [ -n "$overlay" ]; then
    [ -d "$overlay" ] || { echo "overlay is not a directory: $overlay" >&2; exit 64; }
    cp -R "$overlay"/. "$tree/tests/"
fi

# Mirror the flags JS Bay compiles the engine with; warnings are not under test.
cc=${CC:-cc}
inspector_flag=1; [ "$inspector" = on ] || inspector_flag=0
cflags=(-std=gnu11 -O2 -w -fwrapv -D_GNU_SOURCE
    "-DJSBAY_INSPECTOR=$inspector_flag" "-DJSBAY_HEAP_SNAPSHOT=$inspector_flag")
[ "$gc_stress" = 0 ] || cflags+=(-DFORCE_GC_AT_MALLOC=1)
ldlibs=(-lm -lpthread)
[ "$(uname -s)" != Linux ] || ldlibs+=(-ldl)
cd "$tree"
echo "== building $engine (patched=$patched inspector=$inspector gc-stress=$gc_stress) in $tree" >&2
if [ "$engine" = quickjs_ng ]; then
    "$cc" "${cflags[@]}" -I. quickjs.c dtoa.c libregexp.c libunicode.c quickjs-libc.c \
        run-test262.c "${ldlibs[@]}" -o run-test262
    "$cc" "${cflags[@]}" -I. quickjs.c dtoa.c libregexp.c libunicode.c quickjs-libc.c \
        qjs.c gen/repl.c gen/standalone.c "${ldlibs[@]}" -o qjs
else
    version=$(cat VERSION)
    cflags+=("-DCONFIG_VERSION=\"$version\"")
    if "$cc" compat/test-closefrom.c -o /dev/null 2>/dev/null; then cflags+=(-DHAVE_CLOSEFROM); fi
    libsrc=(quickjs.c dtoa.c libregexp.c libunicode.c cutils.c quickjs-libc.c)
    # quickjs-finalizer.patch calls one hook that JS Bay's C wrapper defines (it runs finalizers added through JS_AddRuntimeFinalizer). The qjs CLI adds none, so an empty hook matches what the wrapper does for it.
    printf 'typedef struct JSRuntime JSRuntime;\nvoid jsbay_qjs_JS_RunRuntimeFinalizers(JSRuntime *rt) { (void)rt; }\n' >finalizer_hook.c
    libsrc+=(finalizer_hook.c)
    "$cc" "${cflags[@]}" -DCONFIG_CC=\"cc\" -DCONFIG_PREFIX=\"/usr/local\" -I. \
        qjsc.c "${libsrc[@]}" "${ldlibs[@]}" -o qjsc
    ./qjsc -s -c -o repl.c -m repl.js
    "$cc" "${cflags[@]}" -I. qjs.c repl.c "${libsrc[@]}" "${ldlibs[@]}" -rdynamic -o qjs
    # test_bjson.js imports tests/bjson.so, a native module resolved against qjs.
    shared_flags=(-shared -fPIC)
    [ "$(uname -s)" != Darwin ] || shared_flags+=(-undefined dynamic_lookup)
    "$cc" "${cflags[@]}" -DJS_SHARED_LIBRARY "${shared_flags[@]}" -I. tests/bjson.c -o tests/bjson.so
fi

# Manifest lines: `engine|kind|path|value`; kind is `skip` (value = reason) or `args` (value = extra qjs arguments, quickjs only). Path is relative to the engine tree. engine may be `*`. The tables below are tab-separated `path<TAB>value` files, which keeps this script usable with bash 3.2.
skips=$work/skips.tsv
argtab=$work/args.tsv
: >"$skips"
: >"$argtab"
while IFS='|' read -r m_engine m_kind m_path m_value; do
    case "$m_engine" in ''|'#'*) continue ;; esac
    [ "$m_engine" = "$engine" ] || [ "$m_engine" = '*' ] || continue
    if [ ! -f "$tree/$m_path" ]; then
        echo "manifest entry names a missing file: $m_path" >&2
        exit 65
    fi
    case "$m_kind" in
        skip)
            [ -n "$m_value" ] || { echo "skip without a reason: $m_path" >&2; exit 65; }
            printf '%s\t%s\n' "$m_path" "$m_value" >>"$skips" ;;
        args) printf '%s\t%s\n' "$m_path" "$m_value" >>"$argtab" ;;
        *) echo "unknown manifest kind '$m_kind' for $m_path" >&2; exit 65 ;;
    esac
done <"$manifest"

if [ "$engine" = quickjs_ng ]; then
    # Reuse upstream's own exclusion semantics: tests.conf [exclude] lists fixtures and helpers; gc-stress-skip.txt lists tests too slow for GC stress.
    awk '/^\[/ {sec=$0; next} sec=="[exclude]" && NF && $0 !~ /^#/ {
        printf "%s\tlisted in upstream tests.conf [exclude]: fixture, helper or benchmark, not a standalone case\n", $1}' \
        tests.conf >>"$skips"
    if [ "$gc_stress" = 1 ]; then
        grep -v '^[[:space:]]*\(#\|$\)' gc-stress-skip.txt |
            awk '{printf "%s\tlisted in upstream gc-stress-skip.txt: too allocation-heavy under FORCE_GC_AT_MALLOC\n", $1}' >>"$skips" || true
    fi
fi
# First entry for a path wins, so the manifest can override upstream reasons.
lookup() { awk -F '\t' -v k="$2" '$1 == k {print $2; exit}' "$1"; }

run_with_timeout() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$timeout_secs" "$@"; }

pass=0; fail=0; skip=0; timed_out=0
failed=()
out=$work/case.out
while IFS= read -r path; do
    if [ -n "$filter" ] && ! printf '%s\n' "$path" | grep -Eq -- "$filter"; then continue; fi
    reason=$(lookup "$skips" "$path")
    if [ -n "$reason" ]; then
        printf 'SKIP    %s  (%s)\n' "$path" "$reason"
        skip=$((skip + 1))
        continue
    fi
    if [ "$engine" = quickjs_ng ]; then
        cmd=(./run-test262 -c tests.conf -f "$path")
    else
        read -r -a qargs <<<"$(lookup "$argtab" "$path")"
        cmd=(./qjs ${qargs[@]+"${qargs[@]}"} "$path")
    fi
    start=$SECONDS
    status=0
    run_with_timeout "${cmd[@]}" >"$out" 2>&1 </dev/null || status=$?
    took=$((SECONDS - start))
    if [ "$status" -eq 0 ]; then
        printf 'PASS    %s  (%ss)\n' "$path" "$took"
        pass=$((pass + 1))
        continue
    fi
    if [ "$status" -eq 142 ]; then
        printf 'TIMEOUT %s  (>%ss)\n' "$path" "$timeout_secs"
        timed_out=$((timed_out + 1))
    else
        printf 'FAIL    %s  (exit %s)\n' "$path" "$status"
        fail=$((fail + 1))
    fi
    failed+=("$path")
    sed -e 's/^/        | /' "$out" | head -n 30 || true
done < <(find tests -type f \( -name '*.js' -o -name '*.mjs' \) | LC_ALL=C sort)

attempted=$((pass + fail + timed_out))
echo
echo "engine=$engine patched=$patched inspector=$inspector gc_stress=$gc_stress"
echo "attempted=$attempted pass=$pass fail=$fail timeout=$timed_out skip=$skip"
if [ "${#failed[@]}" -gt 0 ]; then
    printf 'failed: %s\n' "${failed[@]}"
fi
if [ "$attempted" -eq 0 ]; then
    echo "no test was attempted" >&2
    exit 1
fi
[ "$fail" -eq 0 ] && [ "$timed_out" -eq 0 ]
