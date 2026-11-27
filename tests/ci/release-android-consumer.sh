#!/usr/bin/env bash
# Deploy the packaged Maven repository, run its assembled APK, and exercise its SDK classes and native libraries on ART.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
archive=${1:?usage: release-android-consumer.sh maven.zip version gradle backend [mvn]}
version=${2:?version required}
gradle=${3:?Gradle executable required}
backend=${4:?backend required}
maven=${5:-${MVN:-mvn}}
case "$backend" in
  quickjs) artifacts=(jsbay-quickjs jsbayquickjs) ;;
  quickjs_ng) artifacts=(jsbay-quickjs-ng jsbayquickjsng) ;;
  *) echo "unsupported backend: $backend" >&2; exit 2 ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/jsbay-release-android.XXXXXX")
trap 'rm -rf "$work"' EXIT
unzip -q "$archive" -d "$work/repository"
artifact=
for candidate in "${artifacts[@]}"; do
    if [[ -s "$work/repository/io/jsbay/$candidate/$version/$candidate-$version.aar" ]]; then
        artifact=$candidate
        break
    fi
done
if [[ -z $artifact ]]; then
    echo "Maven archive has no artifact for backend $backend version $version" >&2
    exit 1
fi
module="$work/repository/io/jsbay/$artifact/$version"
aar="$module/$artifact-$version.aar"
test -s "$aar"
printf '%s\n' "$backend" | cmp - <(unzip -p "$aar" assets/jsbay-backend.txt)
zig build --build-file "$root/build.zig" tool -- check-maven "$module" "$version" "$backend" "$artifact"
bash "$root/tests/android-sdk/run-maven-deploy-file-consumer.sh" \
    "$archive" "$version" "$backend" "$maven" "$gradle" --run-on-device
unzip -q "$aar" classes.jar 'jni/*' -d "$work/aar"
test -s "$work/aar/classes.jar"
ANDROID_SMOKE_SKIP_BUILD=true ANDROID_SMOKE_JNI_LIBS="$work/aar/jni" \
    JSBAY_ANDROID_CLASSES_JAR="$work/aar/classes.jar" GRADLE_BIN="$gradle" \
    bash "$root/tests/ci/run-android-device-smoke.sh"
