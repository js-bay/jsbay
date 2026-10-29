#!/usr/bin/env bash
# Run the pinned native formatter without a language runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-check}"
case "$MODE" in check|fix|self-test) ;; *) echo 'Usage: native-style.sh check|fix|self-test [--files file ...]' >&2; exit 2 ;; esac
if [ "$#" -gt 0 ]; then shift; fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/jsbay-native-style.XXXXXX")"
DOWNLOAD=''
cleanup() {
    rm -rf "$WORK"
    if [ -n "$DOWNLOAD" ]; then rm -rf "$DOWNLOAD"; fi
}
trap cleanup EXIT
FORMATTER="${CLANG_FORMAT:-}"
if [ -z "$FORMATTER" ]; then
    case "$(uname -s)" in
        Darwin) system=darwin ;;
        Linux) system=linux ;;
        MINGW*|MSYS*) system=windows ;;
        *) echo 'Unsupported host; set CLANG_FORMAT to clang-format 20.1.8.' >&2; exit 2 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) arch=arm64 ;;
        x86_64|amd64) arch=x86_64 ;;
        *) echo 'Unsupported architecture; set CLANG_FORMAT.' >&2; exit 2 ;;
    esac
    name=clang-format
    if [ "$system" = windows ]; then name=clang-format.exe; fi
    directory="${JSBAY_QUALITY_CACHE:-$HOME/.cache/js-bay/quality}/clang-format/20.1.8/$system-$arch"
    FORMATTER="$directory/$name"
    if [ ! -f "$FORMATTER" ]; then
        lock="$ROOT/scripts/quality/native-tools.lock.json"
        url="$(jq -er --arg target "$system-$arch" '.archives[$target].url' "$lock")"
        expected="$(jq -er --arg target "$system-$arch" '.archives[$target].sha256' "$lock")"
        mkdir -p "$directory"
        DOWNLOAD="$(mktemp -d "$directory/.download.XXXXXX")"
        curl --fail --location --silent --show-error "$url" -o "$DOWNLOAD/formatter.zip"
        actual="$(shasum -a 256 "$DOWNLOAD/formatter.zip")"
        if [ "${actual%% *}" != "$expected" ]; then
            echo 'clang-format download checksum mismatch.' >&2
            exit 2
        fi
        unzip -p "$DOWNLOAD/formatter.zip" "clang_format/data/bin/$name" > "$DOWNLOAD/$name"
        test -s "$DOWNLOAD/$name"
        chmod +x "$DOWNLOAD/$name"
        mv -f "$DOWNLOAD/$name" "$FORMATTER"
        rm -rf "$DOWNLOAD"
        DOWNLOAD=''
    fi
fi
version="$("$FORMATTER" --version)"
if ! printf '%s\n' "$version" | grep -Eq 'clang-format version 20\.1\.8([^0-9.]|$)'; then
    echo "clang-format 20.1.8 is required; found: $version" >&2
    exit 2
fi
arguments=("--style=file:$ROOT/sdk/.clang-format")
if [ "$MODE" = self-test ]; then
    for suffix in c cpp m; do
        source="$WORK/Probe.$suffix"
        printf 'int main(){int value=1;return value;}\n' > "$source"
        if "$FORMATTER" "${arguments[@]}" --dry-run --Werror "$source" > "$WORK/diagnostics" 2>&1; then
            echo "Malformed $suffix source unexpectedly passed." >&2
            exit 1
        fi
        grep -q 'clang-format-violations' "$WORK/diagnostics"
        "$FORMATTER" "${arguments[@]}" -i "$source"
        "$FORMATTER" "${arguments[@]}" --dry-run --Werror "$source"
        cp "$source" "$WORK/once"
        "$FORMATTER" "${arguments[@]}" -i "$source"
        cmp "$source" "$WORK/once"
    done
    echo 'Native format self-test: C/C++/Objective-C rejected, fixed, unchanged on repeat'
    exit 0
fi
files=()
if [ "$#" -gt 0 ]; then
    if [ "$1" != --files ] || [ "$#" -lt 2 ]; then
        echo 'Expected --files followed by at least one source.' >&2
        exit 2
    fi
    shift
    files=("$@")
else
    cd "$ROOT"
    find sdk/android/jsbay/src/main/cpp sdk/apple/Sources/JsBayObjC sdk/harmony/src/main/cpp \
        tests/apple-sdk tests/harmony-sdk/node_napi \
        -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.m' \) -print0 > "$WORK/files"
    while IFS= read -r -d '' source; do files+=("$source"); done < "$WORK/files"
fi
if [ "${#files[@]}" -eq 0 ]; then echo 'No SDK native sources found.' >&2; exit 2; fi
if [ "$MODE" = fix ]; then arguments+=(-i); else arguments+=(--dry-run --Werror); fi
"$FORMATTER" "${arguments[@]}" "${files[@]}"
printf 'Native SDK %s: %s files\n' "$MODE" "${#files[@]}"
