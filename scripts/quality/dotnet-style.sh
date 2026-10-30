#!/usr/bin/env bash
# Format every C# SDK and consumer source with the pinned SDK's Roslyn tools.
set -euo pipefail
MODE="${1:-check}"
case "$MODE" in check|fix|self-test) ;; *) echo 'Usage: dotnet-style.sh [check|fix|self-test]' >&2; exit 2 ;; esac
source "$(dirname "$0")/dotnet-common.sh"

if [ "$MODE" = self-test ]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-dotnet-style-test.XXXXXX")"
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
    printf '\ninternal sealed class FormattingProbe{internal static int Check(bool input){if(input)return 1;return 0;}}\n' >> "$WORK/tests/dotnet-sdk/Program.cs"
    if env -u GITHUB_ACTIONS -u CI -u TF_BUILD "$WORK/scripts/quality/dotnet-style.sh" check > "$WORK/expected-diagnostics.log" 2>&1; then
        echo 'Malformed C# formatting unexpectedly passed.' >&2
        exit 1
    else
        echo "Expected rejection exit: $?"
    fi
    if ! grep -Eq 'WHITESPACE|IDE0011' "$WORK/expected-diagnostics.log"; then
        sed -E 's/^##\[[^]]*\]/# /g; s/##\[[^]]*\]/# /g' "$WORK/expected-diagnostics.log" >&2
        echo 'Style check failed without the expected source diagnostic.' >&2
        exit 1
    fi
    sed -E 's/^##\[[^]]*\]/# /g; s/##\[[^]]*\]/# /g' "$WORK/expected-diagnostics.log"
    "$WORK/scripts/quality/dotnet-style.sh" fix
    find "$WORK/sdk" "$WORK/tests" -type f -name '*.cs' -exec cksum {} \; | sort > "$WORK/once.checksums"
    "$WORK/scripts/quality/dotnet-style.sh" fix
    find "$WORK/sdk" "$WORK/tests" -type f -name '*.cs' -exec cksum {} \; | sort > "$WORK/twice.checksums"
    cmp "$WORK/once.checksums" "$WORK/twice.checksums"
    echo '.NET style self-test: malformed source rejected, fix passed, second fix unchanged'
    exit 0
fi

for project in "${PROJECTS[@]}"; do
    if [ "$MODE" = fix ]; then
        "$DOTNET_BIN" format whitespace "$project" --verbosity minimal
        "$DOTNET_BIN" format style "$project" --severity warn --verbosity minimal
        "$DOTNET_BIN" format whitespace "$project" --verbosity minimal
    fi
    "$DOTNET_BIN" format whitespace "$project" --verify-no-changes --verbosity minimal
    "$DOTNET_BIN" format style "$project" --severity warn --verify-no-changes --verbosity minimal
done
printf '.NET style: SDK and consumer checked with SDK %s\n' "$EXPECTED_DOTNET"
