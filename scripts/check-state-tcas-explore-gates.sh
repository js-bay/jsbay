#!/usr/bin/env bash
# Bash 3.2+ (macOS /bin/bash) and Bash 4+ (typical Linux CI). Avoid Bash-4-only builtins such as mapfile.
# Also bans explore.bfs on every scanned harness except an explicit allowlist
# (Scheduler-value Snap bfs only): state_tcas_js_event_loop_harness.zig.
# Live Driver/Engine and any future state_tcas_* harness stay act-log + dfs/dfsKeyed.
set -euo pipefail

if [[ -z "${BASH_VERSINFO:-}" ]]; then
  echo "check-state-tcas-explore-gates: bash is required (Bash 3.2+)" >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v rg >/dev/null 2>&1; then
  echo "check-state-tcas-explore-gates: ripgrep (rg) required" >&2
  exit 1
fi

explore_files=()
# Prefer a pipe over process substitution so macOS Bash 3.2 and Linux Bash 4+ behave the same.
while IFS= read -r f; do
  [[ -n "$f" ]] && explore_files+=("$f")
done <<EOF
$(find src/tests -maxdepth 1 -name 'state_tcas*_harness.zig' | sort)
EOF
if [[ ${#explore_files[@]} -eq 0 ]]; then
  echo "check-state-tcas-explore-gates: no state_tcas*_harness.zig files under src/tests" >&2
  exit 1
fi

# Only value-typed Scheduler Snap may call explore.bfs.
bfs_allowlist=(
  src/tests/state_tcas_js_event_loop_harness.zig
)

is_bfs_allowed() {
  local f="$1"
  local a
  for a in "${bfs_allowlist[@]}"; do
    if [[ "$f" == "$a" ]]; then
      return 0
    fi
  done
  return 1
}

fail=0

for f in "${explore_files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "missing explore harness: $f" >&2
    fail=1
    continue
  fi
  # Call-site patterns only (comments may mention the ban). Matches Ungated, dispatchEventsLimited, and .loop.dispatchEvents(
  if rg -n --pcre2 'dispatchEventsUngated\s*\(|dispatchEventsLimited\s*\(|\.loop\.dispatchEvents\s*\(' "$f"; then
    echo "FORBIDDEN in explore harness $f: L2 Ungated call or loop.dispatchEvents*" >&2
    fail=1
  fi
  if ! is_bfs_allowed "$f"; then
    if rg -n --pcre2 'explore\.bfs\s*\(' "$f"; then
      echo "FORBIDDEN in $f: explore.bfs (allowlist: Scheduler-value harness only; use act-log + dfs/dfsKeyed)" >&2
      fail=1
    fi
  fi
done

for a in "${bfs_allowlist[@]}"; do
  if [[ ! -f "$a" ]]; then
    echo "missing bfs allowlist harness: $a" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "check-state-tcas-explore-gates: failed (see above)" >&2
  exit 1
fi

echo "state_tcas explore gates: scanned ${#explore_files[@]} harness file(s); no L2 Ungated / dispatchEventsLimited / loop.dispatchEvents in explore; explore.bfs only on allowlist (${#bfs_allowlist[@]} file(s))"
