#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-check}"
case "$MODE" in check|fix) ;; *) echo "usage: $0 [check|fix]" >&2; exit 2 ;; esac
CACHE="${JSBAY_QUALITY_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/jsbay-quality}"
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
mkdir -p "$CACHE"

fetch() {
    local name="$1" url="$2" expected="$3" path="$CACHE/$1" actual
    if [ ! -f "$path" ]; then
        curl --fail --location --silent --show-error "$url" -o "$path.download"
        mv "$path.download" "$path"
    fi
    actual="$(shasum -a 256 "$path")"
    if [ "${actual%% *}" != "$expected" ]; then
        echo "SHA-256 mismatch: $path" >&2
        exit 1
    fi
}

fetch ktlint-1.5.0.jar https://github.com/pinterest/ktlint/releases/download/1.5.0/ktlint a16be01dcc480aab2f55f444b620142152f66e31564b3b9376506d624c28a2ad
fetch google-java-format-1.24.0.jar https://github.com/google/google-java-format/releases/download/v1.24.0/google-java-format-1.24.0-all-deps.jar 812f805f58112460edf01bf202a8e61d0fd1f35c0d4fabd54220640776ec57a1

cd "$ROOT"
kotlin_flags=()
java_flags=(--dry-run --set-exit-if-changed)
if [ "$MODE" = fix ]; then
    kotlin_flags=(-F)
    java_flags=(--replace)
fi
"$JAVA" -jar "$CACHE/ktlint-1.5.0.jar" ${kotlin_flags[@]+"${kotlin_flags[@]}"} 'sdk/android/**/*.kt' 'sdk/android/**/*.kts' 'tests/android-sdk/**/*.kt'
"$JAVA" -jar "$CACHE/google-java-format-1.24.0.jar" "${java_flags[@]}" tests/android-sdk/*.java
