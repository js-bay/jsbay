# Testing

## CI

CI has four layers. The workflow files define the commands; a configured job is not evidence that a device test has run.

PR CI keeps **aggressive aggregation** (few coherent jobs, not a micro-matrix). Modest splits exist only where they cut wall-clock: Linux governance vs engine backends in parallel, and iOS Simulator peeled from macOS desktop. Zig `.zig-cache` is restored via [`setup-zig`](../.github/actions/setup-zig/action.yml) on every job.

| Layer | Entry | Coverage |
| --- | --- | --- |
| Pull requests and main | [`ci.yml`](../.github/workflows/ci.yml) | `linux` governance (privacy, actionlint, tools/packages, portable SDK quality). `linux-engine` matrix (`quickjs_ng`, `quickjs`): engine/consumers, Test262, Inspector/GC on ng. `macos` desktop (tools/packages, Apple SDK quality, quickjs_ng engine suite and Darwin consumers, jsc, Inspector end-to-end, dual-pack `-Dbackends=quickjs_ng,jsc` packed/create_with_options/adversarial filters plus quickjs+quickjs_ng configure reject). `macos-ios` host-architecture iOS Simulator smoke (`JSBAY_APPLE_SMOKE=simulator`). `macos-android` native core, AAR, host R8, and Android Lint. `windows` quickjs_ng. Upstream QuickJS regression runs on **main pushes** (and daily extended), not every PR. Android ART API 24 and 35, and the Linux NDK build of the release AAR, run on daily extended `linux`, not on pull requests. The quickjs_ng three-slice XCFramework runs on daily extended `macos`; `quickjs` and `jsc` packaging stay on release. |
| Daily and manual extension | [`extended-tests.yml`](../.github/workflows/extended-tests.yml) | One job per runner image (`linux`, `linux-arm`, `macos`, `macos-intel`, `windows`, `windows-arm`): native backends/optimize variants, stress/GC/OOM, zev contention/TSan, Android ART API 24+35 and the Linux NDK release AAR (linux), Darwin quickjs_ng transport-off / inspector-disabled / dispatch / Test262, the quickjs_ng three-slice XCFramework, plus diagnostic/benchmark contracts (macos) |
| Release acceptance | [`release.yml`](../.github/workflows/release.yml) | L1 desktop libs one job per runner image; L2 Apple backends sequential on macos; L2 Android kept as its own skippable job; assemble + tag publish stay separate. Consumers, licenses, ABI, version, commit, backend and checksums checked |
| Provisioned devices | [`device-tests.yml`](../.github/workflows/device-tests.yml) | Explicitly dispatched Android / iOS / Harmony on distinct self-hosted runners (already one job per platform choice; not further merged) |

The reusable [`mobile-tests.yml`](../.github/workflows/mobile-tests.yml) still owns Android Emulator / iOS Simulator definitions for manual `workflow_dispatch`, including a full `build-apple.sh` XCFramework. Extended `linux` runs Android ART and R8 consumers on API 24 and API 35 and builds the Linux NDK core and release AAR. PR `macos-android` is the pull-request compile, AAR, host R8, and Android Lint gate. PR `macos-ios` runs `JSBAY_APPLE_SMOKE=simulator`, which builds only the host-architecture simulator slice, reuses an image-provisioned iPhone when one exists, and does not assemble the three-slice XCFramework. Daily extended `macos` runs the full quickjs_ng XCFramework and simulator smoke. An Emulator result does not replace ARM64 Android hardware, and a Simulator result does not replace an iPhone result. Harmony host N-API tests do not establish that a device Worker can load the HAR.

[`sdk-quality.yml`](../.github/workflows/sdk-quality.yml) is dispatch-only for official Harmony lint on a provisioned runner; portable and Apple SDK quality checks run inside CI's platform jobs.

Repository-tool and the five independent package suites run once per Linux/macOS PR host, rather than once per backend. Backend steps use `test-engine`, which excludes those package suites. The daily Linux ARM64 job adds package execution for that architecture. Harmony host facade tests already execute the native host consumer, so CI invokes the facade entry once.

Desktop runners have explicit OS and architecture labels. Windows disables the optional POSIX HTTP/WebSocket transport while retaining engine, timer, thread and self-driven loop tests. Its public consumers include C, Zig and .NET. Apple Swift/Objective-C consumers run on ARM64 macOS; Intel macOS extension jobs cover the engine and desktop consumers. Inspector E2E, idle wake and signal shutdown use Node.js 24 on Linux/macOS, including its global WebSocket implementation.

The fixed, digest-verified Test262 manifest remains the declared conformance scope. Broader GC/OOM and concurrency tests are separate daily jobs; they do not turn that subset into a full Test262 claim. Shared-runner benchmark timing is observational. Use fixed hardware before making performance regressions a release gate.

The PR `macos` job runs the Test262 runner contract, including the JSC host capability probe, so that contract stays on Apple. quickjs_ng transport-off, inspector-disabled, location dispatch, and the pinned Test262 subset run on `linux-engine` for every pull request and again on daily macOS, where they cover Darwin without stretching the pull-request job. Daily macOS also runs diagnostic, benchmark provenance, operation metadata, Objective-C failure and host SDK benchmark contracts. The benchmark contract defaults to all supported host and ArkTS checks; `--host-only` is for hosted runners and `--arkts-only` is for the provisioned Harmony runner after it builds the matching native archive.

Hosted jobs that run .NET set `MSBUILDDISABLENODEREUSE` and `UseSharedCompilation=false`, then run `dotnet build-server shutdown` before the job ends, so a leftover compiler process does not hold the runner after the steps finish. `linux` keeps a full git history for the pull-request commit privacy check. Engine jobs use the default shallow checkout; measured checkout time did not depend on full history. [`setup-zig`](../.github/actions/setup-zig/action.yml) also restores Zig's global cache, because the first `zig build` in a job compiles the build runner there. On the measured run that compile was about 80 seconds and showed up inside Linux privacy and macOS `test-tools`, while zig's own summary only counted the tests.

### Device runner configuration

Self-hosted jobs are opt-in and never gate a PR while waiting for unavailable hardware. Register the matching label before dispatch:

- `jsbay-android-device`: connected ARM64/x86_64 Android hardware, SDK platform/build-tools 35, NDK 28.2.13676358, JDK 17, `GRADLE_BIN`, and `ADB`/`ANDROID_SERIAL` when selecting a device. The smoke script selects libraries from the device ABI and executes both plain and R8 consumers.
- `jsbay-ios-device` with macOS/ARM64: Xcode and a connected provisioned iPhone; `JSBAY_IOS_DEVICE_ID`, `JSBAY_IOS_SIGNING_IDENTITY`, `JSBAY_IOS_PROVISIONING_PROFILE`, `JSBAY_IOS_ENTITLEMENTS` and `JSBAY_IOS_BUNDLE_ID`. The job builds consumers from the checkout, signs them with runner-owned credentials, installs and runs the app, checks success markers, then removes its test app. Signing files and device identifiers must remain outside the source tree.
- `jsbay-harmony-sdk12`: official Code Linter/ETS and native SDK, `DEVECO_SDK_HOME`, `HVIGORW`, `OHPM`, and the formatter environment described in [SDK quality](../sdk/QUALITY.md). The job builds the matching OpenHarmony core, compiles real ArkTS fixtures, removes fixture exports, and stages a HAR. It does not claim device/HAP execution.

Manual release validation does not publish a GitHub Release. Only a version-tag push reaches the write-enabled publish job. Device and Harmony jobs require their provisioning; absent credentials or runners are unmeasured, not passing tests.

Runner choices are based on the [GitHub-hosted runner list](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), the [macOS ARM64 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md), and the [Android Emulator action](https://github.com/ReactiveCircus/android-emulator-runner).

## Local checks

```sh
zig build test -Dbackend=quickjs_ng --summary all
zig build test-tools --summary all
zig build tool -- check-docs
zig build tool -- check-tooling
bash tests/test262/run.sh --backend quickjs_ng
bash tests/qjs-regression/run.sh --engine quickjs_ng
bash tests/process-isolation/run.sh
# Device / simulator (optional; needs hardware):
#   bash tests/android-sdk/run-process-isolation-device.sh
#   bash tests/apple-sdk/run-process-isolation-sim.sh
#   bash tests/harmony-sdk/run-process-isolation-device.sh
```

`tests/process-isolation/run.sh` builds a fault-injection archive (test-only
`-Dfault-injection=true`) and proves a Zig/native abort kills only the child
process. Android hardware and iOS Simulator runners do the same on-device / in-sim;
Harmony may SKIP exec under SELinux without a HAP. Default product builds must
leave that option off.

The root test command includes independent package suites. Use the package directory to run one package alone. The `tests/` directory lists consumer, SDK, and command-driver entry points.

## Test262 subset

`tests/test262/run.sh` builds an isolated C-ABI host and runs the fixed subset in [`tests/test262/manifest.json`](../tests/test262/manifest.json). It is a regression suite, not a full Test262 conformance claim.

```sh
bash tests/test262/run.sh --backend quickjs_ng --output /tmp/test262-ng.json
bash tests/test262/run.sh --backend quickjs --source-root /path/to/test262 --output /tmp/test262-qjs.json
bash tests/test262_runner_contract.sh
```

The manifest pins the upstream revision, cases, harness files, licenses, and digests. Without `--source-root`, the runner downloads only declared verified files; with it, missing or mismatched inputs fail. Missing source, digest mismatch, build failure, timeout, unsupported variants, and failed cases fail the run. Reproduce a new failure against the matching unpatched engine before classifying it.

## QuickJS upstream regressions

`tests/qjs-regression/run.sh` runs each engine's upstream suite from a temporary tree prepared with the same patches as `build.zig`. It tests patches; `zig build test` covers Zig integration.

```sh
bash tests/qjs-regression/run.sh --engine quickjs_ng
bash tests/qjs-regression/run.sh --engine quickjs
bash tests/qjs-regression/run.sh --engine quickjs_ng --inspector off
bash tests/qjs-regression/run.sh --engine quickjs --unpatched
```

The runner fails when no case runs, or when a case fails or times out. Its [manifest](../tests/qjs-regression/manifest.txt) records every exception with a reason. Use `--unpatched` to confirm a new failure before adding an exception.
