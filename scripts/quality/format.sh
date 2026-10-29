#!/usr/bin/env bash
# Format SDK sources with the platform tools; checks live in pawl.yaml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$#" -eq 0 ]; then set -- native android apple harmony dotnet; fi
# Validate all targets before applying any changes.
for target in "$@"; do
    case "$target" in
        native|android|apple|harmony|dotnet) ;;
        *) echo "Unknown platform: $target" >&2; exit 2 ;;
    esac
done
bash "$ROOT/scripts/quality/native-style.sh" fix
done_targets=' native '
for target in "$@"; do
    case "$done_targets" in *" $target "*) continue ;; esac
    done_targets="$done_targets$target "
    bash "$ROOT/scripts/quality/$target-style.sh" fix
done
