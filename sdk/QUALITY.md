# SDK quality checks

Checks are defined in `pawl.yaml`. Run them from the repository root:

```sh
make check
make check CHECKS=native-format,android-style,android-lint
make check CHECKS=native-format,apple-style,apple-lint
make check CHECKS=native-format,harmony-style
make check CHECKS=native-format,dotnet-style,dotnet-lint
```

`make check` runs `pawl measure` directly. Each check exits 0 only when the real tool succeeds; missing tools, wrong versions, violating sources, missing reports, or checker failures make pawl exit non-zero. It verifies that the current tools pass; it does not need a regression baseline and does not create or update snapshots; it is not the baseline-diff result of `pawl check`. You can run `pawl measure --only <dimension-list>`, or set `PAWL` to a specific binary. With no `CHECKS` selection, all eight checks run, so every platform tool must be installed.

One-shot formatting uses Make and sh:

```sh
make format
make format PLATFORMS=android
make format PLATFORMS="apple dotnet"
bash scripts/quality/format.sh harmony
```

With no platform selected, every platform is formatted. Formatting first handles the SDK C, C++, and Objective-C implementations, headers, and native consumers, then calls each selected platform's existing format tool; unknown platforms are rejected before any file is changed. After formatting, pawl runs the matching checks. Extra static-analyzer fixes can be applied with `dotnet-lint.sh fix` alone.

Shared native format config is `sdk/.clang-format`; Kotlin and C# editor rules live in the root `.editorconfig`. Sources, declarations, samples, and external consumers are covered by their checks; compiler-generated directories are excluded from source formatting.

| Scope | Format tools | Static checks |
| --- | --- | --- |
| Android | ktlint 1.5.0, google-java-format 1.24.0 | Android Lint, Gradle 8.9, AGP 8.7.3, Kotlin/Java compile |
| Apple | swift-format 6.3.0 from Xcode 26.5 | Swift language mode 5, ObjC compile diagnostics, Clang analyzer, warnings as errors; macOS 11 compile target |
| Harmony | Huawei Code Linter 1.0.0, API 12 ETS 5.0.0.71 parser/fixer | Official Code Linter style and semantic rules, with per-file probes that verify actual scan coverage |
| C# | dotnet format from .NET SDK 8.0.426 | Roslyn .NET 8 recommended rules; SDK and consumers enable the test branch; warnings as errors |
| C/C++/ObjC | clang-format 20.1.8 | Compiler diagnostics run via the matching platform build |

Quality scripts use Bash. Downloads and report handling use `curl`, `unzip`, `shasum`, `jq`, and similar commands; they do not depend on Python. Kotlin/Java tools download into a user cache and verify a fixed SHA-256. clang-format uses a binary archive pinned by URL and SHA-256 in a lockfile, and `unzip` extracts only the executable; the lockfile is `scripts/quality/native-tools.lock.json`. Set `JSBAY_QUALITY_CACHE` to choose the cache directory. A `CLANG_FORMAT` path override must still pass the version check. CI pins pawl to 0.8.2.

## Platform environments

Android needs JDK 17, Gradle 8.9, Android SDK 35, and NDK 28. Set `JAVA_HOME` and `ANDROID_SDK_ROOT`; set `GRADLE` when Gradle is not on `PATH`. `JSBAY_JNI_LIBS` may point at the dual-ABI native library directory from `build-android.sh` for checks that match the shipping AAR. Run `bash scripts/quality/android-style.sh check|fix` alone for Kotlin/Java format only.

Apple selects Xcode 26.5, or set `SWIFT_FORMAT` to the official 6.3.0 tool. Checks use the compiler and SDK chosen by `xcrun`; CI pins `DEVELOPER_DIR` so a default Xcode update does not silently change format rules. The eight illegal ObjC `init`/`new` entry points have compile-reject tests.

Harmony: set `CODELINTER` to the official binary and `HARMONY_ETS_SDK` to a real API 12 `ets` directory. The script validates SDK metadata; it uses a temporary project to adapt older checkers and does not change the project's Hvigor config. The tool may return 0 when diagnostics exist and may omit some diagnostics from the report; the wrapper reads the full log, the report, and per-file coverage probes together.

C#: install the SDK named in the root `global.json`, or set `DOTNET` to its binary. Do not auto-roll to another SDK. `fix` keeps the existing `DllImport` ABI; public members named after JavaScript types such as `Object` and `String` use per-member suppressions instead of turning off whole-class naming rules.

## Build, run, and tool self-tests

Beyond source checks, the existing external consumers in CI must still pass: Android strict JNI, pre/post-R8 consumers and AAR; Apple Swift/ObjC dual-backend consumers. Android `tests/android-sdk/run-r8-host.sh <libjsbay.a>` actually runs the shrunk JVM classes and checks JNI-dependent names; that does not replace Android ART on-device runs.

Harmony `tests/harmony-sdk/build_har.sh` feeds conformance, recursive-callback, and Worker samples to a real ArkTS compiler, then cleans the test sources and rebuilds the shipping HAR. The default fixture keeps compatible API 12 and target API 20. To exercise a real SDK 12, set `HARMONY_TARGET_SDK_VERSION='5.0.0(12)'` explicitly; the script only changes an out-of-tree temporary fixture. Each configuration needs a matching `DEVECO_SDK_HOME`, `HVIGORW`, `OHPM`, and OpenHarmony `JSBAY_LIBRARY`. A higher SDK's compatibility mode is not proof that a lower SDK compiles cleanly.

```sh
bash scripts/quality/native-style.sh self-test
bash scripts/quality/apple-style.sh self-test
bash scripts/quality/dotnet-style.sh self-test
bash scripts/quality/dotnet-lint.sh self-test
bash tests/harmony-sdk/style-consumer.sh
```

These self-tests inject real violations into temporary sources, require the check to reject, then pass after fix, and require a second fix to leave files unchanged. They do not modify SDK sources.

`.github/workflows/sdk-quality.yml` runs native, Android format, C#, and Apple checks on push/PR; Android Lint runs in the existing AAR build job. Harmony official checks run via the `workflow_dispatch` `harmony` option and need a self-hosted runner labeled `jsbay-harmony-sdk12` with the Code Linter/ETS environment above. Repo config does not prove that runner is deployed; without it the job waits and does not count as passed.
