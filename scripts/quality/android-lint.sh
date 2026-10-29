#!/usr/bin/env bash
# Android Lint and Kotlin/Java compilation use the same pinned Gradle as the AAR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GRADLE_BIN="${GRADLE:-gradle}"
if ! command -v "$GRADLE_BIN" >/dev/null 2>&1; then
    echo 'Gradle 8.9 is required; install it or set GRADLE to its executable.' >&2
    exit 2
fi
version="$("$GRADLE_BIN" --version)"
if ! printf '%s\n' "$version" | grep -qx 'Gradle 8.9'; then
    echo 'Gradle 8.9 is required.' >&2
    exit 2
fi
arguments=(--no-daemon --console=plain :jsbay:lintRelease)
if [ -n "${JSBAY_JNI_LIBS:-}" ]; then
    arguments+=("-PjsbayJniLibs=$JSBAY_JNI_LIBS")
fi
cd "$ROOT/sdk/android"
"$GRADLE_BIN" "${arguments[@]}"
