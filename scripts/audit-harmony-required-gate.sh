#!/usr/bin/env bash
set -euo pipefail

repo=${1:-${GH_REPO:-js-bay/jsbay}}
required_check='Harmony HAR required'
gh_bin=${GH_BIN:-gh}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-gate-audit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if ! "$gh_bin" api "repos/$repo/actions/runners" --paginate --slurp > "$tmp/runner-pages.json"; then
  echo "Could not read runners for $repo; authenticate gh and retry." >&2
  exit 2
fi
jq 'if type == "array" then {runners: [.[].runners[]?]} else . end' "$tmp/runner-pages.json" > "$tmp/runners.json"
if ! "$gh_bin" api "repos/$repo/rules/branches/main" --paginate --slurp > "$tmp/rule-pages.json"; then
  echo "Could not read main branch rules for $repo; authenticate gh and retry." >&2
  exit 2
fi
jq 'if length > 0 and (.[0] | type) == "array" then add else . end' "$tmp/rule-pages.json" > "$tmp/rules.json"
classic_state=absent
if "$gh_bin" api "repos/$repo/branches/main/protection/required_status_checks" > "$tmp/classic.json" 2> "$tmp/classic.err"; then
  classic_state=available
elif ! grep -Fq 'HTTP 404' "$tmp/classic.err"; then
  echo "Could not determine classic branch protection for $repo: $(cat "$tmp/classic.err")" >&2
  exit 2
fi

runner_ready=$(jq -r '[.runners[]? | select(.status == "online") | .labels[]?.name] | any(. == "jsbay-harmony-sdk12")' "$tmp/runners.json")
check_required=$(jq -r --arg check "$required_check" '
  any(.[]?;
    .type == "required_status_checks" and (
      any(.parameters.required_status_checks[]?; .context == $check) or
      any(.parameters.required_status_checks.contexts[]?; . == $check)
    ) and .parameters.strict_required_status_checks_policy == true
  )
' "$tmp/rules.json")
if [[ $classic_state == available ]]; then
  classic_required=$(jq -r --arg check "$required_check" \
    '(.strict == true) and (([.contexts[]?, .checks[]?.context] | any(. == $check)))' \
    "$tmp/classic.json")
  if [[ $classic_required == true ]]; then check_required=true; fi
fi

failed=0
if [[ $runner_ready == true ]]; then
  echo 'PASS: an online runner has the jsbay-harmony-sdk12 label.'
else
  echo 'FAIL: no online runner has the jsbay-harmony-sdk12 label.' >&2
  failed=1
fi
if [[ $check_required == true ]]; then
  echo "PASS: main requires the '$required_check' status check."
else
  echo "FAIL: main does not require the strict '$required_check' status check." >&2
  failed=1
fi

if ((failed)); then
  echo 'Resolve the failed conditions above before treating Harmony builds as operational; an active required check blocks merges until the matching runner and workflow are available.' >&2
  exit 1
fi
