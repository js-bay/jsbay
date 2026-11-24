# JsBay Android SDK

> Lifecycle protocol v2: deploy matching core/JNI/classes and migrate close as described in [owner destruction](../../docs/owner-destruction.md#android-lifecycle-migration). `Engine.close()` is owner-only and may defer; `DedicatedEngineThread.close()` is now nonblocking. Check `closeStatus()` and keep the original owner alive until creator drain completes. A new major SDK release is required for this behavioral migration; no release is published here.

`Engine` and `Value` are owner-thread objects. Close each owned `Value` and
the engine on the thread that created the engine. Callback arguments are
borrowed; call `retain()` before keeping one after the callback returns.
`requestInterrupt()`, `stopLoop()`, `beginShutdown()`, `shutdownStatus()`, and `cancel()` are the cross-thread control-plane operations.

Do **not** create an `Engine` on the UI/main `Looper` in production: synchronous
`evaluate` will ANR. Prefer `Engine.createOnBackground(id) { engine -> ... }`,
which starts a `HandlerThread` named `jsbay-<id>` and runs `ready` on that owner
thread. Quit the returned thread only after creator drain reports `CloseStatus.COMPLETE`.

Same-process native crashes still kill the host process; time/memory limits and
wrong-thread checks are soft failures only. Use a separate `android:process` when
the app must survive an engine fault. See `docs/host-isolation.md`.

Observability: optional `LogHandler` / `EventHandler` on create (or
`setEventHandler` later), plus owner-thread `getMemoryUsage()` and `runGc()` for
reporting pipelines.

`postScript` and `postFence` submit work to the core FIFO; they do not add an Android queue. Capture completion outcomes after their checkpoint, including script exceptions and cancellation. `beginShutdown(graceMillis)` and a sealing `postFence` provide graceful drain; `shutdownStatus()` reports the core phase. `cancel()` is scoped to the immutable generation captured when this `Engine` was created, so it cannot cancel a replacement using the same id. `setExecutionBudget` sets the per-entry bound; `setExecutionTimeLimit` and `setMemoryLimit` retain their existing instance-wide meanings.

## Minimum supported versions

The Android SDK requires **API 24 (Android 7.0)** and newer. That floor is set in
[`jsbay/build.gradle.kts`](jsbay/build.gradle.kts) (`minSdk = 24`) and in the
repository-root [`build-android.sh`](../../build-android.sh)
(`ANDROID_API_LEVEL=24`). The Zig/NDK shared library is built against the same
API level so newer Bionic symbols stay out of `libjsbay.so`.

Repository `./build-android.sh` defaults `QUICKJS_BACKEND` to classic `quickjs`. Set `QUICKJS_BACKEND=quickjs_ng` for the NG variant. The script resolves the repository from its own location; pass an explicit source root only when needed, and never hardcode a developer machine path.

## CDP debugging

Call `engine.startInspector(0)` on the Engine owner thread to start the bundled CDP HTTP/WebSocket listener and receive its selected port. Connect a DevTools client to that port, then call `engine.stopInspector()` on the same owner thread before closing the Engine. Both QuickJS-family packages expose breakpoints, stepping, and paused-frame evaluation.

The host app must declare `<uses-permission android:name="android.permission.INTERNET" />` in its Android manifest before opening the listener. Prefer a debug manifest when debugging is only available in debug builds. The AAR does not add this permission automatically.

For a USB-connected device, forward the returned loopback port before opening Chrome DevTools: `adb forward tcp:<host-port> tcp:<device-port>`. The host can then run `node tests/inspector/e2e.cjs --host 127.0.0.1 --port <host-port> --debugger-flow`. The app must keep its owner Looper running while the debugger is attached; do not run ordinary application work from a paused debugger command.

`tests/android-sdk/run-inspector-device.sh <jniLibs>` runs this contract through `DedicatedEngineThread` in an ADB shell process on an attached device. This validates SDK ownership and forwarding, but does not exercise an installed app's sandbox or manifest permissions. Supply both `libjsbay.so` and `libjsbay_android.so` for the device ABI, and set `JAVA_HOME`, `ANDROID_SDK_ROOT`, and `KOTLIN_GRADLE_LIB` for the test compiler. The driver creates a temporary device payload and ADB forwarding rule, then stops the engine and removes both.

## Owner thread and multi-instance hosts

Create one `Engine` per instance id on a **dedicated** Looper thread. Do not create engines on the process main/UI thread: automatic LoopDriver attach would schedule JavaScript there and share one thread across many instances.

`requestClose()` / no-argument `close()` request asynchronously; an independent owner task attempts `drainClose()` and only quits its Looper after completion. A pending attempt needs a later retry; `closeStatus()` reports VM progress, not thread-exit proof. A timed-out bounded close remains pending until the original creator can unwind and drain.

`DedicatedEngineThread.lifecycleState` reports `RUNNING`, `CLOSING`, `CLOSED`, or `FAILED`. New `post` and foreign `runOnOwner` admission stops at `CLOSING`; already admitted work and internal creator drain can still finish. `CLOSED` requires native drain completion and exit from the owner Looper. `isClosed` includes `FAILED` as a terminal SDK state, but failure alone does not prove native reclamation: retain `closeStatus()` checks and the original creator requirement. A bounded `close(timeoutMillis)` uses one deadline for drain acknowledgement and thread join; the no-argument overload remains nonblocking.

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

`DedicatedEngineThread.post` / `runOnOwner` marshal work onto the owner thread. `close()` closes the engine on that thread and quits its Looper. Calling `close(timeoutMillis)` waits for shutdown completion and throws `DedicatedEngineThreadTimeoutException` when the deadline expires before shutdown completes; callers cannot assume the engine is destroyed or that its instance ID is safe for reuse until shutdown completes. Threads without a Looper still use `runLoop()` on the owner thread; never call `runLoop()` on the main/UI thread.

JavaScript throws are `JsBayException` values. The original thrown `Value` is available through `getValue()` in Java and `value` in Kotlin. Use `describeAndClose()` when only display text is needed: it reads and closes the original value, preserves embedded NUL and Unicode, and returns `"JavaScript exception"` if coercion throws another JavaScript value. Owner-thread, borrowed, and stale-value errors still throw instead of becoming fallback text.

Use `details()` to copy message, stack text, and available source location while keeping the original value open. `detailsAndClose()` returns the same snapshot and closes the value; `describeDetailedAndClose()` returns both message and stack, adding the message before the stack unless its first line already contains the message. It returns the message when the stack is empty and the stack when the message is empty. The immutable snapshot can be handed across threads. Location fields use the engine properties `fileName`/`sourceURL`, `lineNumber`/`line`, and `columnNumber`/`column`; the SDK does not parse stack text to guess locations. A JavaScript getter that throws while reading metadata leaves that field empty, while owner-thread, borrowed, and stale-value errors remain visible.

Run `make check CHECKS=native-format,android-style,android-lint` from the repository to execute the pawl checks. Use `make format PLATFORMS=android` to format JNI, Kotlin, Gradle Kotlin DSL, and Java consumers. The style script downloads ktlint 1.5.0 and google-java-format 1.24.0 into the user cache, verifies their SHA-256 checksums, and requires JDK 17. Native formatting uses `bash scripts/quality/native-style.sh check`.

`tests/android-sdk/run-r8-host.sh <libjsbay.a>` compiles external Java and Kotlin consumers, runs them with strict JNI checking, then shrinks them with Android build-tools 35.0.0 R8 and runs the resulting JVM classes again. Set `JAVA_HOME`, `ANDROID_SDK_ROOT`, and `KOTLIN_GRADLE_LIB` when using custom installations. This checks the JNI names preserved by the packaged consumer rules; Android device execution remains covered by `run-device.sh` and `run-r8-device.sh`.

For release staging, build the native libraries with `./build-android.sh`, then publish the `release` variant to a local Maven repository. Gradle uses the `backend` file next to `jniLibs` to select the Maven coordinate. Set `jsbayBackend` to require a specific engine and reject any mismatch.

```sh
gradle -PjsbayVersion=0.1.0 -PjsbayBackend=quickjs_ng \
  -PjsbayJniLibs=/absolute/path/to/jniLibs -PjsbayMavenRepo=/absolute/path/to/repository \
  :jsbay:publishReleasePublicationToStagingRepository
```

The `quickjs` engine produces `io.jsbay:jsbayquickjs:0.1.0`; `quickjs_ng` produces `io.jsbay:jsbayquickjsng:0.1.0`. Each package includes the AAR, POM, Gradle module metadata, and an engine marker in the AAR. The marker is checked against the backend recorded by `build-android.sh`, so a package cannot silently claim the other engine's coordinate. The POM declares Kotlin stdlib 1.9.22 for Java-only consumers. The repository generated by this command is a local staging repository.

Add the matching artifact as an implementation dependency in the app's `build.gradle.kts`. Replace `<version>` with a published release version and select one engine per application, since both packages provide the same SDK classes and native library names.

```kotlin
dependencies {
    implementation("io.jsbay:jsbayquickjsng:<version>")
}
```

For downloads from GitHub Packages, add this repository to `dependencyResolutionManagement.repositories` in `settings.gradle.kts`, alongside `google()` and `mavenCentral()`.

```kotlin
maven {
    url = uri("https://maven.pkg.github.com/js-bay/jsbay")
    content { includeGroup("io.jsbay") }
    credentials {
        username = providers.gradleProperty("githubPackagesUser").orElse(providers.environmentVariable("GITHUB_ACTOR")).get()
        password = providers.gradleProperty("githubPackagesToken").orElse(providers.environmentVariable("GITHUB_PACKAGES_TOKEN")).get()
    }
}
```

GitHub Packages requires authentication even for public Maven packages. For a local build, set `githubPackagesUser` and `githubPackagesToken` in your user Gradle properties with a GitHub username and a classic personal access token with `read:packages`. A GitHub Actions workflow with read access to the package can use its `GITHUB_TOKEN` as `GITHUB_PACKAGES_TOKEN`.

For a build without GitHub Packages credentials, download the engine's Maven ZIP from the public GitHub Release, extract it to a directory, and use `maven { url = uri("/absolute/path/to/extracted/maven-repository") }` instead. Use the same dependency coordinate with either repository.

The release workflow deploys the checked AAR, POM, Gradle module metadata, and sources jar from the Maven ZIP with `scripts/publish-android-maven.sh` and the repository's `GITHUB_TOKEN`. A retry reuses the version when all four files are identical and stops if the version is incomplete or has different contents. `tests/android-sdk/run-maven-deploy-file-consumer.sh <maven.zip> <version> <backend> <mvn> <gradle> [--run-on-device]` deploys to a local file repository, builds an independent consumer, and optionally runs the installed app on an attached Android device.
