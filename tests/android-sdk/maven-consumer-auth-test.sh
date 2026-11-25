#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-maven-consumer-auth-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
token_marker="consumer-contract-$$"
cat > "$temporary/module-metadata.json" <<'EOF'
{
  "variants": [
    {"name":"releaseVariantReleaseApiPublication","attributes":{"org.gradle.category":"library","org.gradle.usage":"java-api"},"capabilities":[{"group":"io.jsbay","name":"jsbay-quickjs","version":"0.1.1-rc.1"},{"group":"io.jsbay","name":"jsbayquickjs","version":"0.1.1-rc.1"}]},
    {"name":"releaseVariantReleaseRuntimePublication","attributes":{"org.gradle.category":"library","org.gradle.usage":"java-runtime"},"capabilities":[{"group":"io.jsbay","name":"jsbay-quickjs","version":"0.1.1-rc.1"},{"group":"io.jsbay","name":"jsbayquickjs","version":"0.1.1-rc.1"}]},
    {"name":"releaseVariantReleaseSourcePublication","attributes":{"org.gradle.category":"documentation","org.gradle.usage":"java-runtime","org.gradle.docstype":"sources"},"capabilities":[]}
  ]
}
EOF
node "$root/tests/android-sdk/check-maven-capabilities.mjs" "$temporary/module-metadata.json" jsbay-quickjs jsbayquickjs 0.1.1-rc.1
node - "$temporary/module-metadata.json" "$temporary/missing-capability.module" <<'NODE'
const { readFileSync, writeFileSync } = require('node:fs')
const [source, destination] = process.argv.slice(2)
const metadata = JSON.parse(readFileSync(source, 'utf8'))
metadata.variants[0].capabilities = metadata.variants[0].capabilities.filter(capability => capability.name !== 'jsbayquickjs')
writeFileSync(destination, JSON.stringify(metadata))
NODE
if node "$root/tests/android-sdk/check-maven-capabilities.mjs" "$temporary/missing-capability.module" jsbay-quickjs jsbayquickjs 0.1.1-rc.1 >"$temporary/missing-capability.log" 2>&1; then
    echo 'expected capability checker to reject a missing legacy capability on a library variant' >&2
    exit 1
fi
grep -Fq 'releaseVariantReleaseApiPublication does not declare capability io.jsbay:jsbayquickjs:0.1.1-rc.1' "$temporary/missing-capability.log"
mkdir -p "$temporary/bin" "$temporary/local-repository"
mkdir -p "$temporary/local-repository/io/jsbay/jsbayquickjs/0.1.1-rc.1"
printf '%s\n' '<project />' > "$temporary/local-repository/io/jsbay/jsbayquickjs/0.1.1-rc.1/jsbayquickjs-0.1.1-rc.1.pom"
mkdir -p "$temporary/local-repository/io/jsbay/jsbayquickjsng/0.1.1-rc.1"
printf '%s\n' '<project />' > "$temporary/local-repository/io/jsbay/jsbayquickjsng/0.1.1-rc.1/jsbayquickjsng-0.1.1-rc.1.pom"

cat > "$temporary/bin/gradle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
project=
arguments="$*"
while (($#)); do
    if [[ $1 == -p ]]; then project=$2; shift 2; else shift; fi
done
test -n "$project"
if [[ ${EXPECT_GITHUB_AUTH:-false} == true ]]; then
    test "${GITHUB_ACTOR:-}" = test-actor
    test "${GITHUB_TOKEN:-}" = "${EXPECTED_GITHUB_TOKEN:-}"
    test "${JSBAY_MAVEN_REPO:-}" = "${EXPECTED_MAVEN_REPO:-https://maven.pkg.github.com/js-bay/jsbay}"
    test "${JSBAY_MAVEN_REPOSITORY_AUTH:-}" = github-packages
    grep -Fq 'System.getenv("GITHUB_TOKEN")' "$project/settings.gradle.kts"
    grep -Fq 'create<BasicAuthentication>("basic")' "$project/settings.gradle.kts"
    ! grep -Fq "$EXPECTED_GITHUB_TOKEN" "$project/settings.gradle.kts"
else
    test -z "${JSBAY_MAVEN_REPOSITORY_AUTH:-}"
fi
if [[ -n ${EXPECTED_ARTIFACT:-} ]]; then test "$JSBAY_MAVEN_ARTIFACT" = "$EXPECTED_ARTIFACT"; fi
if [[ ${EXPECT_CURL_AUTH_CLEANUP:-false} == true ]]; then
    test -n "${ANDROID_MAVEN_CONSUMER_OUT:-}"
    test ! -e "$ANDROID_MAVEN_CONSUMER_OUT/curl-auth"
fi
if [[ ${EXPECT_LEGACY_REMOTE_ARTIFACTS:-false} == true ]]; then
    case "${JSBAY_MAVEN_BACKEND:-}:$JSBAY_MAVEN_ARTIFACT" in
        quickjs:jsbayquickjs|quickjs_ng:jsbayquickjsng) ;;
        *) echo "unexpected legacy Maven artifact for ${JSBAY_MAVEN_BACKEND:-unknown}: $JSBAY_MAVEN_ARTIFACT" >&2; exit 1 ;;
    esac
fi
if [[ ${EXPECT_CURRENT_REMOTE_ARTIFACTS:-false} == true ]]; then
    case "${JSBAY_MAVEN_BACKEND:-}:$JSBAY_MAVEN_ARTIFACT" in
        quickjs:jsbay-quickjs|quickjs_ng:jsbay-quickjs-ng) ;;
        *) echo "unexpected current Maven artifact for ${JSBAY_MAVEN_BACKEND:-unknown}: $JSBAY_MAVEN_ARTIFACT" >&2; exit 1 ;;
    esac
fi
if [[ " $arguments " == *" :app:dependencies "* ]]; then
    printf '%s\n' 'org.jetbrains.kotlin:kotlin-stdlib:1.9.22'
fi
if [[ " $arguments " == *" :app:assembleDebug "* ]]; then
    mkdir -p "$project/app/build/outputs/apk/debug"
    : > "$project/app/build/outputs/apk/debug/app-debug.apk"
fi
EOF
chmod +x "$temporary/bin/gradle"

cat > "$temporary/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
config=
url=
while (($#)); do
    case "$1" in
        --config) config=$2; shift 2 ;;
        http://*|https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
test -n "$url"
if [[ -n ${CURL_CALL_FILE:-} ]]; then : > "$CURL_CALL_FILE"; fi
test -s "$config"
grep -Fq "${EXPECTED_GITHUB_TOKEN:-}" "$config"
if [[ ${CURL_FAIL:-false} == true ]]; then exit 22; fi
if [[ ${LEGACY_COORDINATE_ONLY:-false} == true && $url == *jsbay-quickjs* ]]; then
    printf 404
else
    printf 200
fi
EOF
chmod +x "$temporary/bin/curl"

cat > "$temporary/bin/unzip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = -Z1
printf '%s\n' \
    lib/arm64-v8a/libjsbay.so \
    lib/arm64-v8a/libjsbay_android.so \
    lib/x86_64/libjsbay.so \
    lib/x86_64/libjsbay_android.so
EOF
chmod +x "$temporary/bin/unzip"

cat > "$temporary/bin/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == shell ]]; then
    shift
    backend=
    while (($#)); do
        if [[ $1 == backend ]]; then backend=$2; shift 2; else shift; fi
    done
    printf 'INSTRUMENTATION_RESULT: jsbayResult=%s:42\n' "$backend"
    printf 'INSTRUMENTATION_CODE: -1\n'
fi
EOF
chmod +x "$temporary/bin/adb"

PATH="$temporary/bin:$PATH" ANDROID_MAVEN_CONSUMER_OUT="$temporary/local-out" EXPECTED_ARTIFACT=jsbayquickjs \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    "$temporary/local-repository" 0.1.1-rc.1 "$temporary/bin/gradle" quickjs \
    >"$temporary/local-consumer.log" 2>&1 || { cat "$temporary/local-consumer.log" >&2; exit 1; }
grep -Fq 'PASS: Maven consumer assembled' "$temporary/local-consumer.log"
PATH="$temporary/bin:$PATH" ANDROID_MAVEN_CONSUMER_OUT="$temporary/local-ng-out" EXPECTED_ARTIFACT=jsbayquickjsng \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    "$temporary/local-repository" 0.1.1-rc.1 "$temporary/bin/gradle" quickjs_ng \
    >"$temporary/local-ng-consumer.log" 2>&1 || { cat "$temporary/local-ng-consumer.log" >&2; exit 1; }

if PATH="$temporary/bin:$PATH" GITHUB_ACTOR=test-actor env -u GITHUB_TOKEN \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    https://maven.pkg.github.com/js-bay/jsbay 0.1.1-rc.1 "$temporary/bin/gradle" quickjs \
    2>"$temporary/missing-token.log"; then
    echo 'expected GitHub Packages consumer to reject a missing token' >&2
    exit 1
fi
grep -Fq 'GITHUB_TOKEN is required for GitHub Packages' "$temporary/missing-token.log"

PATH="$temporary/bin:$PATH" EXPECT_GITHUB_AUTH=true GITHUB_ACTOR=test-actor GITHUB_TOKEN="$token_marker" EXPECTED_GITHUB_TOKEN="$token_marker" \
    GITHUB_REPOSITORY=Example-Owner/Sample-Repo EXPECTED_MAVEN_REPO=https://maven.pkg.github.com/example-owner/sample-repo \
    EXPECT_CURRENT_REMOTE_ARTIFACTS=true \
    ADB="$temporary/bin/adb" \
    bash "$root/tests/android-sdk/run-maven-remote-consumer.sh" 0.1.1-rc.1 "$temporary/bin/gradle" \
    >"$temporary/remote-consumer.log" 2>&1 || { cat "$temporary/remote-consumer.log" >&2; exit 1; }
grep -Fq 'INSTRUMENTATION_RESULT: jsbayResult=quickjs:42' "$temporary/remote-consumer.log"
grep -Fq 'INSTRUMENTATION_RESULT: jsbayResult=quickjs_ng:42' "$temporary/remote-consumer.log"
if grep -Fq "$token_marker" "$temporary/remote-consumer.log"; then
    echo 'GitHub token appeared in consumer output' >&2
    exit 1
fi

if PATH="$temporary/bin:$PATH" EXPECT_GITHUB_AUTH=true GITHUB_ACTOR=test-actor GITHUB_TOKEN="$token_marker" EXPECTED_GITHUB_TOKEN="$token_marker" \
    GITHUB_REPOSITORY=Example-Owner/Sample-Repo EXPECTED_MAVEN_REPO=https://maven.pkg.github.com/example-owner/sample-repo \
    LEGACY_COORDINATE_ONLY=true \
    bash "$root/tests/android-sdk/run-maven-remote-consumer.sh" 0.1.1-rc.1 "$temporary/bin/gradle" \
    >"$temporary/legacy-only-consumer.log" 2>&1; then
    echo 'expected remote consumer to reject a legacy-only Maven publication' >&2
    exit 1
fi
grep -Fq 'Current Maven coordinate io.jsbay:jsbay-quickjs:0.1.1-rc.1 is missing; legacy fallback is disabled for remote verification' "$temporary/legacy-only-consumer.log"

mkdir -p "$temporary/success-out"
PATH="$temporary/bin:$PATH" EXPECT_GITHUB_AUTH=true GITHUB_ACTOR=test-actor GITHUB_TOKEN="$token_marker" EXPECTED_GITHUB_TOKEN="$token_marker" \
    EXPECTED_ARTIFACT=jsbay-quickjs EXPECT_CURL_AUTH_CLEANUP=true \
    ANDROID_MAVEN_CONSUMER_OUT="$temporary/success-out" \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    https://maven.pkg.github.com/js-bay/jsbay 0.1.1-rc.1 "$temporary/bin/gradle" quickjs \
    >"$temporary/success-consumer.log" 2>&1 || { cat "$temporary/success-consumer.log" >&2; exit 1; }
test ! -e "$temporary/success-out/curl-auth"

backslash_out="$temporary/backslash-out"
mkdir -p "$backslash_out"
if PATH="$temporary/bin:$PATH" GITHUB_ACTOR=test-actor GITHUB_TOKEN='invalid\token' CURL_CALL_FILE="$temporary/backslash-curl-called" \
    ANDROID_MAVEN_CONSUMER_OUT="$backslash_out" \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    https://maven.pkg.github.com/js-bay/jsbay 0.1.1-rc.1 "$temporary/bin/gradle" quickjs \
    >"$temporary/backslash-consumer.log" 2>&1; then
    echo 'expected Maven consumer to reject backslashes in credentials' >&2
    exit 1
fi
grep -Fq 'Invalid GitHub Packages credentials' "$temporary/backslash-consumer.log"
test ! -e "$temporary/backslash-curl-called"
test ! -e "$backslash_out/curl-auth"

mkdir -p "$temporary/curl-failure-out"
if PATH="$temporary/bin:$PATH" GITHUB_ACTOR=test-actor GITHUB_TOKEN="$token_marker" EXPECTED_GITHUB_TOKEN="$token_marker" CURL_FAIL=true \
    ANDROID_MAVEN_CONSUMER_OUT="$temporary/curl-failure-out" \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    https://maven.pkg.github.com/js-bay/jsbay 0.1.1-rc.1 "$temporary/bin/gradle" quickjs \
    >"$temporary/curl-failure.log" 2>&1; then
    echo 'expected Maven coordinate probe to fail' >&2
    exit 1
fi
test ! -e "$temporary/curl-failure-out/curl-auth"

printf 'PASS: mocked GitHub Packages authentication path and local Maven compatibility\n'
