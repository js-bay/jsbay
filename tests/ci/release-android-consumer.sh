#!/usr/bin/env bash
# Run the SDK classes and native libraries extracted from the packaged Maven repository.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
archive=${1:?usage: release-android-consumer.sh maven.zip version gradle}
version=${2:?version required}
gradle=${3:?Gradle executable required}
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-release-android.XXXXXX")
trap 'rm -rf "$work"' EXIT
unzip -q "$archive" -d "$work/repository"
module="$work/repository/io/jsbay/js-bay-android/$version"
aar="$module/js-bay-android-$version.aar"
test -s "$aar"
zig build --build-file "$root/build.zig" tool -- check-maven "$module" "$version"
bash "$root/tests/android-sdk/maven-consumer.sh" "$work/repository" "$version" "$gradle"
unzip -q "$aar" classes.jar 'jni/*' -d "$work/aar"
test -s "$work/aar/classes.jar"
ANDROID_SMOKE_SKIP_BUILD=true ANDROID_SMOKE_JNI_LIBS="$work/aar/jni" \
    JSBAY_ANDROID_CLASSES_JAR="$work/aar/classes.jar" GRADLE_BIN="$gradle" \
    bash "$root/tests/ci/run-android-device-smoke.sh"
