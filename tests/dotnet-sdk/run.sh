#!/usr/bin/env bash
set -euo pipefail

backend=${1:?usage: tests/dotnet-sdk/run.sh quickjs_ng|quickjs|jsc}
case "$backend" in quickjs_ng|quickjs|jsc) ;; *) echo "unsupported backend: $backend" >&2; exit 64 ;; esac

dotnet_bin=${DOTNET:-dotnet}
command -v "$dotnet_bin" >/dev/null
optimize=${JSBAY_CI_OPTIMIZE:-Debug}
case "$(uname -s)" in
  # Pin mingw: windows-gnu shared exports match DllImport cdecl names. Native MSVC builds
  # on GHA have produced jsbay.dll without a resolvable jsbay_engine_create entry point.
  MINGW*|MSYS*|CYGWIN*) zig build "-Dbackend=$backend" "-Doptimize=$optimize" -Dtarget=x86_64-windows-gnu -Dlibrary-only=true -Dshared=true -Dinspector-transport=false --summary all ;;
  *) zig build "-Dbackend=$backend" "-Doptimize=$optimize" -Dlibrary-only=true -Dshared=true --summary all ;;
esac
created_artifacts=0
artifacts=${JSBAY_DOTNET_ARTIFACTS:-}
if [[ -z "$artifacts" ]]; then
  artifacts=$(mktemp -d "${TMPDIR:-/tmp}/js-bay-dotnet-consumer.XXXXXX")
  created_artifacts=1
fi
if [[ "$created_artifacts" == 1 ]]; then
  trap 'rm -rf "$artifacts"' EXIT
fi
export JSBAY_DOTNET_ARTIFACTS="$artifacts"
if [[ "$(uname -s)" == Darwin ]]; then
  DYLD_LIBRARY_PATH="$PWD/zig-out/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$dotnet_bin" run -p:JsBayTestHooks=true --project tests/dotnet-sdk/JsBayConsumer.csproj
elif [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  PATH="$PWD/zig-out/bin:$PWD/zig-out/lib:$PATH" "$dotnet_bin" run -p:JsBayTestHooks=true --project tests/dotnet-sdk/JsBayConsumer.csproj
else
  LD_LIBRARY_PATH="$PWD/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$dotnet_bin" run -p:JsBayTestHooks=true --project tests/dotnet-sdk/JsBayConsumer.csproj
fi
