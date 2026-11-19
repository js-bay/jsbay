#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-maven-consumer-auth-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
token_marker="consumer-contract-$$"
mkdir -p "$temporary/bin" "$temporary/local-repository"

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
    test "${JSBAY_MAVEN_REPO:-}" = https://maven.pkg.github.com/js-bay/jsbay
    test "${JSBAY_MAVEN_REPOSITORY_AUTH:-}" = github-packages
    grep -Fq 'System.getenv("GITHUB_TOKEN")' "$project/settings.gradle.kts"
    grep -Fq 'create<BasicAuthentication>("basic")' "$project/settings.gradle.kts"
    ! grep -Fq "$EXPECTED_GITHUB_TOKEN" "$project/settings.gradle.kts"
else
    test -z "${JSBAY_MAVEN_REPOSITORY_AUTH:-}"
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

PATH="$temporary/bin:$PATH" ANDROID_MAVEN_CONSUMER_OUT="$temporary/local-out" \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    "$temporary/local-repository" 0.1.1-rc.1 "$temporary/bin/gradle" quickjs \
    >"$temporary/local-consumer.log" 2>&1
grep -Fq 'PASS: Maven consumer assembled' "$temporary/local-consumer.log"

if PATH="$temporary/bin:$PATH" GITHUB_ACTOR=test-actor env -u GITHUB_TOKEN \
    bash "$root/tests/android-sdk/maven-consumer.sh" \
    https://maven.pkg.github.com/js-bay/jsbay 0.1.1-rc.1 "$temporary/bin/gradle" quickjs \
    2>"$temporary/missing-token.log"; then
    echo 'expected GitHub Packages consumer to reject a missing token' >&2
    exit 1
fi
grep -Fq 'GITHUB_TOKEN is required for GitHub Packages' "$temporary/missing-token.log"

PATH="$temporary/bin:$PATH" EXPECT_GITHUB_AUTH=true GITHUB_ACTOR=test-actor GITHUB_TOKEN="$token_marker" EXPECTED_GITHUB_TOKEN="$token_marker" \
    ADB="$temporary/bin/adb" \
    bash "$root/tests/android-sdk/run-maven-remote-consumer.sh" 0.1.1-rc.1 "$temporary/bin/gradle" \
    >"$temporary/remote-consumer.log" 2>&1
grep -Fq 'INSTRUMENTATION_RESULT: jsbayResult=quickjs:42' "$temporary/remote-consumer.log"
grep -Fq 'INSTRUMENTATION_RESULT: jsbayResult=quickjs_ng:42' "$temporary/remote-consumer.log"
if grep -Fq "$token_marker" "$temporary/remote-consumer.log"; then
    echo 'GitHub token appeared in consumer output' >&2
    exit 1
fi

printf 'PASS: mocked GitHub Packages authentication path and local Maven compatibility\n'
