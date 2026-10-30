#!/usr/bin/env bash
# Analyze every C# SDK and consumer source, including test-hook branches.
set -euo pipefail
MODE="${1:-check}"
case "$MODE" in check|fix|self-test) ;; *) echo 'Usage: dotnet-lint.sh [check|fix|self-test]' >&2; exit 2 ;; esac
source "$(dirname "$0")/dotnet-common.sh"

if [ "$MODE" = self-test ]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-dotnet-lint-test.XXXXXX")"
    trap 'rm -rf "$WORK" "${DOTNET_QUALITY_TEMP:-}"' EXIT
    mkdir -p "$WORK/sdk/dotnet" "$WORK/tests" "$WORK/scripts/quality"
    cp -R "$ROOT/sdk/dotnet/JsBay" "$WORK/sdk/dotnet/"
    cp -R "$ROOT/tests/dotnet-sdk" "$WORK/tests/"
    cp "$ROOT/.editorconfig" "$WORK/"
    cp "$ROOT/global.json" "$WORK/"
    cp "$ROOT/scripts/quality/"dotnet-*.sh "$WORK/scripts/quality/"
    export JSBAY_DOTNET_ARTIFACTS="$WORK/artifacts"
    # Intentional failures must not emit Actions workflow commands as PR annotations.
    unset GITHUB_ACTIONS CI TF_BUILD
    cat >> "$WORK/sdk/dotnet/JsBay/Status.cs" <<'CS'

internal static class AnalyzerProbe
{
    internal static bool HasText(string text) => text.IndexOf('x') >= 0;
}
CS
    if env -u GITHUB_ACTIONS -u CI -u TF_BUILD "$WORK/scripts/quality/dotnet-lint.sh" check > "$WORK/expected-diagnostics.log" 2>&1; then
        echo 'C# analyzer violation unexpectedly passed.' >&2
        exit 1
    else
        echo "Expected rejection exit: $?"
    fi
    if ! grep -q 'CA2249' "$WORK/expected-diagnostics.log"; then
        echo "self-test diagnostics (sanitized summary):" >&2
        grep -Eo 'CA2249' "$WORK/expected-diagnostics.log" | sort -u | sed 's/^/  observed /' >&2 || true
        echo 'Analyzer check failed without the expected CA2249 diagnostic.' >&2
        exit 1
    fi
    # Do not replay MSBuild lines — Actions problem matchers turn `file(line): error CODE:` into annotations.
    grep -Eo 'CA2249' "$WORK/expected-diagnostics.log" | sort -u | sed 's/^/self-test observed /'
    "$WORK/scripts/quality/dotnet-lint.sh" fix
    find "$WORK/sdk" "$WORK/tests" -type f -name '*.cs' -exec cksum {} \; | sort > "$WORK/once.checksums"
    "$WORK/scripts/quality/dotnet-lint.sh" fix
    find "$WORK/sdk" "$WORK/tests" -type f -name '*.cs' -exec cksum {} \; | sort > "$WORK/twice.checksums"
    cmp "$WORK/once.checksums" "$WORK/twice.checksums"
    echo '.NET analyzer self-test: violation rejected, fix passed, second fix unchanged'
    exit 0
fi

for project in "${PROJECTS[@]}"; do
    if [ "$MODE" = fix ]; then
        # The 8.0.426 workspace filters CA2249 by its default info severity even when recommended analysis promotes it to warning. Include info fixes, but retain the existing DllImport marshalling ABI instead of applying the optional source-generated P/Invoke migration automatically.
        "$DOTNET_BIN" format analyzers "$project" --severity info --exclude-diagnostics SYSLIB1054 --verbosity minimal
    fi
    # Build also rejects diagnostics that have no automatic code fix.
    "$DOTNET_BIN" build "$project" --nologo -p:JsBayTestHooks=true -p:AnalysisLevel=8.0-recommended -warnaserror
done
printf '.NET lint: SDK and consumer checked with SDK %s\n' "$EXPECTED_DOTNET"
