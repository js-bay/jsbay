#!/usr/bin/env bash
set -euo pipefail

# CI must install Android platform/build tools 35, Java 17, and Gradle 8.9, then boot an API 35 x86_64 emulator before invoking this script.
usage='usage: run-maven-remote-consumer.sh <version> <gradle-bin>'
version=${1:?$usage}
gradle_bin=${2:?$usage}
[[ $# == 2 ]] || { echo "$usage" >&2; exit 2; }
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo 'invalid Maven package version' >&2; exit 2; }
test -x "$gradle_bin" || { echo 'Gradle executable is missing' >&2; exit 2; }
test -n "${GITHUB_ACTOR:-}" || { echo 'GITHUB_ACTOR is required for GitHub Packages' >&2; exit 2; }
test -n "${GITHUB_TOKEN:-}" || { echo 'GITHUB_TOKEN is required for GitHub Packages' >&2; exit 2; }
github_repository=${GITHUB_REPOSITORY:-}
[[ "$github_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'GITHUB_REPOSITORY must contain an owner and repository name' >&2; exit 2; }
github_repository_lower=$(printf '%s' "$github_repository" | tr '[:upper:]' '[:lower:]')

root=$(cd "$(dirname "$0")/../.." && pwd)
maven_repository="https://maven.pkg.github.com/$github_repository_lower"
for backend in quickjs quickjs_ng; do
    printf 'Testing remote Android Maven package %s (%s)\n' "$version" "$backend"
    bash "$root/tests/android-sdk/maven-consumer.sh" \
        "$maven_repository" "$version" "$gradle_bin" "$backend" --run-on-device --require-current-coordinate
done
