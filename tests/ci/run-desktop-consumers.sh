#!/usr/bin/env bash
# Build and run public desktop consumers against the selected backend.
set -euo pipefail

backend=${1:?usage: tests/ci/run-desktop-consumers.sh quickjs_ng|quickjs|jsc}
case "$backend" in quickjs_ng|quickjs|jsc) ;; *) echo "unsupported backend: $backend" >&2; exit 64 ;; esac
optimize=${JSBAY_CI_OPTIMIZE:-ReleaseFast}

root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/js-bay-desktop-consumers.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$root"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) zig build "-Dbackend=$backend" -Dlibrary-only=true "-Doptimize=$optimize" -Dinspector-transport=false --prefix "$work/core" --summary all ;;
  *) zig build "-Dbackend=$backend" -Dlibrary-only=true "-Doptimize=$optimize" --prefix "$work/core" --summary all ;;
esac

run_dotnet() {
  JSBAY_DOTNET_ARTIFACTS="$work/dotnet" JSBAY_CI_OPTIMIZE="$optimize" tests/dotnet-sdk/run.sh "$backend"
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    archive="$work/core/lib/jsbay.lib"
    zig cc -std=c11 -Wall -Wextra -Werror -Iinclude tests/c_consumer.c "$archive" -o "$work/c-consumer.exe"
    "$work/c-consumer.exe"
    (
      cd tests/zig-consumer
      zig build run "-Dbackend=$backend" -Dinspector-transport=false --summary all
    )
    run_dotnet
    ;;
  *)
    bash tests/run-value-consumers.sh "$work/core/lib/libjsbay.a" "$work/c"
    (
      cd tests/zig-consumer
      zig build run "-Dbackend=$backend" --summary all
    )
    run_dotnet
    ;;
esac

printf 'PASS desktop consumers (%s)\n' "$backend"
