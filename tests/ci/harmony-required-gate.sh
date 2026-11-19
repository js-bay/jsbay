#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
gate="$root/scripts/check-harmony-required-gate.sh"
audit="$root/scripts/audit-harmony-required-gate.sh"
readiness="$root/scripts/check-harmony-runner-readiness.sh"
workflow="$root/.github/workflows/sdk-quality.yml"
local_gate="$root/scripts/check-harmony-local.sh"

test -x "$gate"
test -x "$audit"
test -x "$readiness"
test -x "$local_gate"
grep -Fq 'name: Harmony local gate checks' "$workflow"
grep -Fq "if: github.event_name == 'workflow_dispatch' && inputs.harmony" "$workflow"
grep -Fq 'default: false' "$workflow"
grep -Fq 'needs: [harmony-toolchain, harmony-manual-preflight]' "$workflow"
grep -Fq 'backend: [quickjs_ng, quickjs]' "$workflow"
# shellcheck disable=SC2016
grep -Fq 'HARMONY_SDK12_READY: ${{ vars.HARMONY_SDK12_READY }}' "$workflow"
grep -Fq 'bash tests/ci/harmony-local-gate.sh' "$workflow"
if grep -Eq "if: .*github.event_name == 'push'.*refs/heads/main|if: .*pull_request.*head.repo.full_name" "$workflow"; then
  echo 'The optional self-hosted Harmony runner must not run automatically for pushes or pull requests.' >&2
  exit 1
fi

"$readiness" true
if "$readiness" false; then
  echo 'A false readiness value must stop before the self-hosted build is queued.' >&2
  exit 1
fi
if "$readiness"; then
  echo 'An unset readiness value must stop before the self-hosted build is queued.' >&2
  exit 1
fi
"$gate" success success
if "$gate" success skipped; then
  echo 'The required Harmony check accepted a skipped backend.' >&2
  exit 1
fi
if "$gate" success failure; then
  echo 'The required Harmony check accepted a failed backend.' >&2
  exit 1
fi
if "$gate" cancelled success; then
  echo 'The required Harmony check accepted cancelled prerequisites.' >&2
  exit 1
fi

mock_bin=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-harmony-gate-mock.XXXXXX")
trap 'rm -rf "$mock_bin"' EXIT
cat > "$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  repos/test/project/actions/runners) cat "$GH_RUNNERS_FIXTURE" ;;
  repos/test/project/rules/branches/main) cat "$GH_RULES_FIXTURE" ;;
  repos/test/project/branches/main/protection/required_status_checks)
    if [[ ${GH_CLASSIC_MODE:-missing} == forbidden ]]; then
      echo 'gh: HTTP 403' >&2
      exit 1
    fi
    if [[ ${GH_CLASSIC_MODE:-missing} == missing ]]; then
      echo 'gh: Branch not protected (HTTP 404)' >&2
      exit 1
    fi
    cat "$GH_CLASSIC_FIXTURE"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$mock_bin/gh"
export GH_BIN="$mock_bin/gh"
export GH_RUNNERS_FIXTURE="$mock_bin/runners.json"
export GH_RULES_FIXTURE="$mock_bin/rules.json"
export GH_CLASSIC_FIXTURE="$mock_bin/classic.json"
export GH_CLASSIC_MODE=missing
printf '%s\n' '{"total_count":1,"runners":[{"status":"online","labels":[{"name":"jsbay-harmony-sdk12"}]}]}' > "$GH_RUNNERS_FIXTURE"
printf '%s\n' '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"Harmony HAR required"}]}}]' > "$GH_RULES_FIXTURE"
"$audit" test/project
printf '%s\n' '[{"runners":[]},{"runners":[{"status":"online","labels":[{"name":"jsbay-harmony-sdk12"}]}]}]' > "$GH_RUNNERS_FIXTURE"
printf '%s\n' '[[],[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"Harmony HAR required"}]}}]]' > "$GH_RULES_FIXTURE"
"$audit" test/project
printf '%s\n' '{"total_count":0,"runners":[]}' > "$GH_RUNNERS_FIXTURE"
if "$audit" test/project; then
  echo 'The remote audit accepted a missing Harmony runner.' >&2
  exit 1
fi
printf '%s\n' '{"total_count":1,"runners":[{"status":"online","labels":[{"name":"jsbay-harmony-sdk12"}]}]}' > "$GH_RUNNERS_FIXTURE"
printf '%s\n' '[]' > "$GH_RULES_FIXTURE"
if "$audit" test/project; then
  echo 'The remote audit accepted a missing required check.' >&2
  exit 1
fi
printf '%s\n' '{"strict":true,"contexts":["Harmony HAR required"]}' > "$GH_CLASSIC_FIXTURE"
export GH_CLASSIC_MODE=available
"$audit" test/project
export GH_CLASSIC_MODE=forbidden
if "$audit" test/project; then
  echo 'The remote audit accepted an unreadable branch rule.' >&2
  exit 1
fi

echo 'Harmony required gate tests passed.'
