#!/usr/bin/env bash
# Black-box contract for tests/test262/run.sh. Fixtures live in a temporary source root so --source-root can be verified as strictly offline.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
runner="$root/tests/test262/run.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-test262-contract.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
src="$tmp/source"
mkdir -p "$src/harness" "$src/test/pass" "$src/test/fail" "$src/test/async"
printf '%s\n' 'var assert={sameValue:function(a,b){if(a!==b)throw new Error("sameValue")},throws:function(C,f){try{f()}catch(e){if(e instanceof C)return}throw new Error("throws")}};' >"$src/harness/assert.js"
printf '%s\n' '// fixture sta' >"$src/harness/sta.js"
printf '%s\n' '// fixture async helpers' >"$src/harness/asyncHelpers.js"
printf '%s\n' 'assert.sameValue(1, 1);' >"$src/test/pass/ok.js"
printf '%s\n' 'assert.sameValue(1, 2);' >"$src/test/fail/assert.js"
printf '%s\n' 'throw new TypeError("expected runtime error");' >"$src/test/pass/negative-runtime.js"
printf '%s\n' 'var ;' >"$src/test/pass/negative-parse.js"
printf '%s\n' 'throw new SyntaxError("runtime syntax error");' >"$src/test/fail/runtime-syntax-for-parse.js"
printf '%s\n' 'var ;' >"$src/test/fail/parse-syntax-for-runtime.js"
printf '%s\n' 'throw new SyntaxError("wrong error type");' >"$src/test/fail/wrong-negative-type.js"
printf '%s\n' 'throw { name: "TypeError" };' >"$src/test/fail/forged-negative-name.js"
printf '%s\n' 'globalThis.TypeError = function FakeTypeError() {}; throw { name: "TypeError" };' >"$src/test/fail/overwritten-global-typeerror.js"
printf '%s\n' 'void 0;' >"$src/test/fail/missing-negative-throw.js"
# shellcheck disable=SC2016 # Intentional JavaScript fixture literal; $DONE is not shell expansion.
printf '%s\n' '$DONE();' >"$src/test/async/done.js"
# shellcheck disable=SC2016 # Intentional JavaScript fixture literal; $DONE is not shell expansion.
printf '%s\n' '$DONE(new Error("async failure"));' >"$src/test/async/done-error.js"
# shellcheck disable=SC2016 # Intentional JavaScript fixture literal; $DONE is not shell expansion.
printf '%s\n' '$DONE(); $DONE();' >"$src/test/async/done-twice.js"
# shellcheck disable=SC2016 # Intentional JavaScript fixture literal; $DONE is not shell expansion.
printf '%s\n' 'Promise.resolve().then(function(){throw new Error("late promise error")}); $DONE();' >"$src/test/async/promise-after-done.js"
# shellcheck disable=SC2016 # Intentional JavaScript fixture literal; $DONE is not shell expansion.
printf '%s\n' '/* never calls $DONE */' >"$src/test/async/timeout.js"

sha() { shasum -a 256 "$src/$1" | awk '{print $1}'; }
manifest() {
    local target=$1 mode=$2
    jq -n --arg revision fixture --arg path "$target" --arg sha "$(sha "$target")" --arg mode "$mode" \
      --arg assert_sha "$(sha harness/assert.js)" --arg sta_sha "$(sha harness/sta.js)" --arg async_sha "$(sha harness/asyncHelpers.js)" '
      {schema_version:1,revision:$revision,
       files:[{path:"harness/assert.js",sha256:$assert_sha},{path:"harness/sta.js",sha256:$sta_sha},{path:"harness/asyncHelpers.js",sha256:$async_sha},{path:$path,sha256:$sha}],
       tests:[if $mode == "negative" then
                {path:$path,variants:["sloppy","strict"],includes:["assert.js"],async:false,negative:{phase:"runtime",type:"TypeError"}}
              else
                {path:$path,variants:["sloppy","strict"],includes:["assert.js"],async:($mode == "async")}
              end]}'
}
run_case() {
    local name=$1 path=$2 mode=$3 expected=$4
    local phase=${5:-}
    local error_type=${6:-}
    manifest "$path" "$mode" | jq --arg phase "$phase" --arg error_type "$error_type" '
      if $phase != "" then .tests[0].negative = {phase:$phase,type:$error_type} else . end
    ' >"$tmp/$name.json"
    if "$runner" --backend quickjs_ng --source-root "$src" --manifest "$tmp/$name.json" --output "$tmp/$name.out.json" >"$tmp/$name.stdout" 2>"$tmp/$name.stderr"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$expected" = pass ] && [ "$rc" -ne 0 ]; then
        cat "$tmp/$name.stdout" >&2
        cat "$tmp/$name.stderr" >&2
        return 1
    fi
    if [ "$expected" = fail ] && [ "$rc" -eq 0 ]; then echo "$name unexpectedly passed" >&2; return 1; fi
    jq -e '.attempted == (.passed + .failed + .timed_out + .unsupported) and (.passed | type == "number") and (.failed | type == "number") and (.timed_out | type == "number") and (.unsupported | type == "number")' "$tmp/$name.out.json" >/dev/null
    case "$expected" in
      pass) jq -e '.failed == 0 and .timed_out == 0 and .unsupported == 0 and .passed == 2' "$tmp/$name.out.json" >/dev/null ;;
      fail) jq -e '.failed > 0 or .timed_out > 0' "$tmp/$name.out.json" >/dev/null ;;
    esac
}

[ -x "$runner" ] || { echo "missing runner: $runner" >&2; exit 127; }
run_case pass test/pass/ok.js normal pass
run_case negative test/pass/negative-runtime.js negative pass
run_case parse-negative test/pass/negative-parse.js normal pass parse SyntaxError
run_case async-done test/async/done.js async pass
run_case assert-failure test/fail/assert.js normal fail
run_case async-error test/async/done-error.js async fail
run_case async-timeout test/async/timeout.js async fail
run_case runtime-syntax-is-not-parse test/fail/runtime-syntax-for-parse.js normal fail parse SyntaxError
# A matching SyntaxError is insufficient for a runtime negative: this source never begins execution, so accepting it would collapse parse/runtime phases.
run_case parse-syntax-is-not-runtime test/fail/parse-syntax-for-runtime.js normal fail runtime SyntaxError
run_case wrong-negative-type test/fail/wrong-negative-type.js normal fail runtime TypeError
# The genuine `new TypeError` fixture above must pass. These objects only forge a public name; replacing the global constructor must not alter that check.
run_case forged-negative-name test/fail/forged-negative-name.js normal fail runtime TypeError
run_case overwritten-global-typeerror test/fail/overwritten-global-typeerror.js normal fail runtime TypeError
run_case missing-negative-throw test/fail/missing-negative-throw.js normal fail runtime TypeError
run_case async-done-twice test/async/done-twice.js async fail
run_case async-promise-after-done test/async/promise-after-done.js async fail

# A mismatched source digest is a supply-chain failure, never a skipped case.
manifest test/pass/ok.js normal | jq '.files[-1].sha256 = "00"' >"$tmp/bad-digest.json"
if "$runner" --backend quickjs_ng --source-root "$src" --manifest "$tmp/bad-digest.json" --output "$tmp/bad-digest.out.json" >"$tmp/bad-digest.stdout" 2>"$tmp/bad-digest.stderr"; then
    echo "digest mismatch unexpectedly passed" >&2
    exit 1
fi

# JSC's host cannot independently observe every unhandled Promise rejection. Its report must disclose that limit instead of a bare pass count implying parity with the QuickJS host watcher.
manifest test/async/done.js async >"$tmp/jsc-capabilities.json"
if ! "$runner" --backend jsc --source-root "$src" --manifest "$tmp/jsc-capabilities.json" --output "$tmp/jsc-capabilities.out.json" >"$tmp/jsc-capabilities.stdout" 2>"$tmp/jsc-capabilities.stderr"; then
    cat "$tmp/jsc-capabilities.stdout" >&2
    cat "$tmp/jsc-capabilities.stderr" >&2
    exit 1
fi
jq -e '
  .backend == "jsc" and
  (.capabilities | type == "object") and
  (.capabilities.unhandledPromiseRejection == false) and
  (.capabilities.asyncLimitation | type == "string" and length > 0)
' "$tmp/jsc-capabilities.out.json" >/dev/null
