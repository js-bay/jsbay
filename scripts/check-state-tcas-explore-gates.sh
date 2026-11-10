#!/usr/bin/env bash
# Delegates to the native state_tcas gate checker.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

exec zig build check-state-tcas-explore-gates
