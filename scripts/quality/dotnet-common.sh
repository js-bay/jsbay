#!/usr/bin/env bash
# Shared setup for the pinned SDK and complete managed project list.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOTNET_BIN="${DOTNET:-dotnet}"
EXPECTED_DOTNET=8.0.426
if ! command -v "$DOTNET_BIN" >/dev/null 2>&1; then
    echo "The .NET SDK $EXPECTED_DOTNET is required; install it or set DOTNET to its executable." >&2
    exit 2
fi
cd "$ROOT"
if ! actual_version="$("$DOTNET_BIN" --version)" || [ "$actual_version" != "$EXPECTED_DOTNET" ]; then
    echo "The .NET SDK $EXPECTED_DOTNET is required (found ${actual_version:-unavailable}); set DOTNET to the pinned SDK." >&2
    exit 2
fi
PROJECTS=("$ROOT/sdk/dotnet/JsBay/JsBay.csproj" "$ROOT/tests/dotnet-sdk/JsBayConsumer.csproj")
# Include fault-injection code in the analyzer and formatter workspace.
export JsBayTestHooks=true
if [ -z "${JSBAY_DOTNET_ARTIFACTS:-}" ]; then
    DOTNET_QUALITY_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-dotnet-quality.XXXXXX")"
    trap 'rm -rf "$DOTNET_QUALITY_TEMP"' EXIT
    export JSBAY_DOTNET_ARTIFACTS="$DOTNET_QUALITY_TEMP/artifacts"
fi
