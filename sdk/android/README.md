# JsBay Android SDK

`Engine` and `Value` are owner-thread objects. Close each owned `Value` and
the engine on the thread that created the engine. Callback arguments are
borrowed; call `retain()` before keeping one after the callback returns.
`requestInterrupt()` and `stopLoop()` are the cross-thread operations.

Do **not** create an `Engine` on the UI/main `Looper` in production: synchronous
`evaluate` will ANR. Prefer `Engine.createOnBackground(id) { engine -> ... }`,
which starts a `HandlerThread` named `jsbay-<id>` and runs `ready` on that owner
thread. Quit the returned thread after `engine.close()` on the owner thread.

Same-process native crashes still kill the host process; time/memory limits and
wrong-thread checks are soft failures only. Use a separate `android:process` when
the app must survive an engine fault. See `docs/host-isolation.md`.

Observability: optional `LogHandler` / `EventHandler` on create (or
`setEventHandler` later), plus owner-thread `getMemoryUsage()` and `runGc()` for
reporting pipelines.

## Minimum supported versions

The Android SDK requires **API 24 (Android 7.0)** and newer. That floor is set in
[`jsbay/build.gradle.kts`](jsbay/build.gradle.kts) (`minSdk = 24`) and in the
repository-root [`build-android.sh`](../../build-android.sh)
(`ANDROID_API_LEVEL=24`). The Zig/NDK shared library is built against the same
API level so newer Bionic symbols stay out of `libjsbay.so`.

Repository `./build-android.sh` defaults `QUICKJS_BACKEND` to classic `quickjs`. Set `QUICKJS_BACKEND=quickjs_ng` for the NG variant. The script resolves the repository from its own location; pass an explicit source root only when needed, and never hardcode a developer machine path.

## Owner thread and multi-instance hosts

Create one `Engine` per instance id on a **dedicated** Looper thread. Do not create engines on the process main/UI thread: automatic LoopDriver attach would schedule JavaScript there and share one thread across many instances.

By default, `new Engine(id)` refuses automatic attach when `Looper.myLooper() == Looper.getMainLooper()` and throws `JsBayException(INVALID_ARGUMENT)`. Opt in only when you intentionally own that risk:

```kotlin
Engine(id, EngineOptions(allowMainLooperAttach = true))
```

Prefer the factory that starts a dedicated owner thread:

```kotlin
DedicatedEngineThread.start(instanceId).use { dedicated ->
  dedicated.runOnOwner { engine ->
    engine.evaluate("1 + 2", "boot.js").use { println(it.number()) }
  }
}
```

`DedicatedEngineThread.post` / `runOnOwner` marshal work onto the owner thread. `close()` closes the engine on that thread and quits its Looper. Threads without a Looper still use `runLoop()` on the owner thread; never call `runLoop()` on the main/UI thread.

JavaScript throws are `JsBayException` values. The original thrown `Value` is available through `getValue()` in Java and `value` in Kotlin. Use `describeAndClose()` when only display text is needed: it reads and closes the original value, preserves embedded NUL and Unicode, and returns `"JavaScript exception"` if coercion throws another JavaScript value. Owner-thread, borrowed, and stale-value errors still throw instead of becoming fallback text.

Run `make check CHECKS=native-format,android-style,android-lint` from the repository to execute the pawl checks. Use `make format PLATFORMS=android` to format JNI, Kotlin, Gradle Kotlin DSL, and Java consumers. The style script downloads ktlint 1.5.0 and google-java-format 1.24.0 into the user cache, verifies their SHA-256 checksums, and requires JDK 17. Native formatting uses `bash scripts/quality/native-style.sh check`.

`tests/android-sdk/run-r8-host.sh <libjsbay.a>` compiles external Java and Kotlin consumers, runs them with strict JNI checking, then shrinks them with Android build-tools 35.0.0 R8 and runs the resulting JVM classes again. Set `JAVA_HOME`, `ANDROID_SDK_ROOT`, and `KOTLIN_GRADLE_LIB` when using custom installations. This checks the JNI names preserved by the packaged consumer rules; Android device execution remains covered by `run-device.sh` and `run-r8-device.sh`.

For release staging, publish the `release` variant to a local Maven repository:

```sh
gradle -PjsbayVersion=0.1.0 -PjsbayMavenRepo=/absolute/path/to/repository \
  :jsbay:publishReleasePublicationToStagingRepository
```

It produces `io.jsbay:js-bay-android:0.1.0`, including the AAR, POM, and Gradle module metadata. The POM declares Kotlin stdlib 1.9.22 for Java-only consumers. `io.jsbay` is a staging coordinate; it is not a claim that the artifact has been published to Maven Central.
