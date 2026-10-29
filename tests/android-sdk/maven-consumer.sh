#!/usr/bin/env bash
set -euo pipefail

MAVEN_REPO="${1:?usage: maven-consumer.sh <maven-repo> <version> <gradle-bin>}"
VERSION="${2:?usage: maven-consumer.sh <maven-repo> <version> <gradle-bin>}"
GRADLE_BIN="${3:?usage: maven-consumer.sh <maven-repo> <version> <gradle-bin>}"
OUT="${ANDROID_MAVEN_CONSUMER_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/jsbay-android-maven-consumer.XXXXXX")}"

test -d "$MAVEN_REPO"
test -x "$GRADLE_BIN"
if [ -z "${ANDROID_MAVEN_CONSUMER_OUT:-}" ]; then trap 'rm -rf "$OUT"' EXIT; fi

mkdir -p "$OUT/app/src/main/java/io/jsbay/mavenconsumer"
cat > "$OUT/settings.gradle.kts" <<'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven { url = uri(System.getenv("JSBAY_MAVEN_REPO")) }
        google()
        mavenCentral()
    }
}
rootProject.name = "jsbay-maven-consumer"
include(":app")
EOF
cat > "$OUT/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.application") version "8.7.3" apply false
}
EOF
cat > "$OUT/app/build.gradle.kts" <<'EOF'
plugins { id("com.android.application") }

android {
    namespace = "io.jsbay.mavenconsumer"
    compileSdk = 35
    defaultConfig {
        applicationId = "io.jsbay.mavenconsumer"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1"
    }
}

dependencies { implementation("io.jsbay:js-bay-android:${System.getenv("JSBAY_MAVEN_VERSION")}") }
EOF
cat > "$OUT/app/src/main/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:label="JsBay Maven consumer" />
</manifest>
EOF
cat > "$OUT/app/src/main/java/io/jsbay/mavenconsumer/Main.java" <<'EOF'
package io.jsbay.mavenconsumer;

import io.jsbay.Engine;

final class Main {
  static Engine createEngine() {
    return new Engine(1);
  }
}
EOF

LOG="$OUT/gradle.log"
JSBAY_MAVEN_REPO="$MAVEN_REPO" JSBAY_MAVEN_VERSION="$VERSION" \
    "$GRADLE_BIN" --no-daemon --console=plain -p "$OUT" \
    :app:dependencies --configuration debugRuntimeClasspath >"$LOG" 2>&1
grep -Eq 'org\.jetbrains\.kotlin:kotlin-stdlib(:|[^[:space:]]*:)1\.9\.22' "$LOG"

JSBAY_MAVEN_REPO="$MAVEN_REPO" JSBAY_MAVEN_VERSION="$VERSION" \
    "$GRADLE_BIN" --no-daemon --console=plain -p "$OUT" :app:assembleDebug >>"$LOG" 2>&1
APK="$OUT/app/build/outputs/apk/debug/app-debug.apk"
test -f "$APK"
for abi in arm64-v8a x86_64; do
    for library in libjsbay.so libjsbay_android.so; do
        unzip -Z1 "$APK" | grep -Fx "lib/$abi/$library" >/dev/null
    done
done

printf 'PASS: Maven consumer assembled %s\n' "$APK"
