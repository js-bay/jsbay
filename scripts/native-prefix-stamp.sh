#!/usr/bin/env bash
# Reject native prefixes built from different bridge sources or debugger patches.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="${1:?usage: native-prefix-stamp.sh <escargot|hermes> <write|check> <prefix>}"
MODE="${2:?specify write or check}"
PREFIX="${3:?specify the native install prefix}"
case "$BACKEND" in
    escargot)
        inputs=(scripts/rebuild-escargot-install.sh src/backend/escargot/escargot_bridge.cpp src/backend/escargot/escargot_bridge.h vendor/escargot-debugger.patch)
        ;;
    hermes)
        inputs=(scripts/rebuild-hermes-install.sh src/backend/hermes/hermes_bridge.cpp src/backend/hermes/hermes_bridge.h src/backend/hermes/hermes_esm.cpp src/backend/hermes/hermes_inspector.cpp vendor/hermes-drain-microtasks-hint.patch vendor/hermes-cdp-frame-url.patch vendor/hermes-cdp-cancel-pending.patch vendor/hermes-debugger-step-out.patch)
        ;;
    *) echo 'Unknown native backend.' >&2; exit 2 ;;
esac
case "$MODE" in write|check) ;; *) echo 'Specify write or check.' >&2; exit 2 ;; esac
digest() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}
expected="$(
    {
        printf 'jsbay-native-prefix-v1:%s\n' "$BACKEND"
        cat "$ROOT/scripts/native-prefix-stamp.sh" || exit 1
        for input in "${inputs[@]}"; do
            printf '\n%s\n' "$input"
            cat "$ROOT/$input" || exit 1
        done
    } | digest
)"
expected="${expected%% *}"
stamp="$PREFIX/jsbay-build.sha256"
if [[ "$MODE" == write ]]; then
    printf '%s\n' "$expected" > "$stamp"
elif [[ ! -f "$stamp" || "$(cat "$stamp")" != "$expected" ]]; then
    echo "Native $BACKEND prefix is missing or stale; run scripts/rebuild-$BACKEND-install.sh with the matching install prefix." >&2
    exit 1
fi
