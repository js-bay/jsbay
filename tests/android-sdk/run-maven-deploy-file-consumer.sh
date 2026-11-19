#!/usr/bin/env bash
set -euo pipefail

usage='usage: run-maven-deploy-file-consumer.sh <maven.zip> <version> <backend> <mvn> <gradle> [--run-on-device]'
archive=${1:?$usage}
version=${2:?$usage}
backend=${3:?$usage}
maven=${4:?$usage}
gradle=${5:?$usage}
shift 5
root=$(cd "$(dirname "$0")/../.." && pwd)
target=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-maven-deploy-consumer.XXXXXX")
trap 'rm -rf "$target"' EXIT

MVN="$maven" bash "$root/scripts/publish-android-maven.sh" \
    "$archive" "$version" "$backend" "file://$target" local-test
bash "$root/tests/android-sdk/maven-consumer.sh" "$target" "$version" "$gradle" "$backend" "$@"

printf 'PASS: Maven deployed archive consumed from %s\n' "$target"
