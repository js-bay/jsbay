#!/usr/bin/env bash
set -euo pipefail

readiness=${1:-}
if [[ $readiness != true ]]; then
  echo 'Harmony SDK 12 runner is not marked ready. An administrator must run scripts/audit-harmony-required-gate.sh, provision the matching runner, then set HARMONY_SDK12_READY=true.' >&2
  exit 1
fi

echo 'Harmony runner scheduling is enabled. This setting does not replace successful HAR build results.'
