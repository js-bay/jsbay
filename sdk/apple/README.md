# JsBaySDK

The Apple release zip is a Swift package snapshot. Its single top-level directory contains `Package.swift`, `Sources/`, `Frameworks/JsBay.xcframework`, and license files. A maintainer can publish that directory as a new Git repository with a version tag; no development repository history is needed. After the package repository is available, add its Git URL in Xcode under **File → Add Package Dependencies** and select `JsBaySDK` for Swift or `JsBayObjC` for Objective-C. Apple release packages default to `jsc`; `quickjs` and `quickjs_ng` builds are separate packages and need separate Git URLs. Until a public package repository exists, consumers can add the extracted directory as a local Swift package.

From this repository, `./build-apple.sh` (or `JSBAY_APPLE_BACKEND`) selects the engine. The intended product default is `jsc`. Override with `./build-apple.sh quickjs` or `./build-apple.sh quickjs_ng` when you need those variants. Packaging scripts should resolve the checkout from their own path (or an explicit `JSBAY_SOURCE_ROOT`); do not bake in a machine-specific directory.

When declaring the dependency in another `Package.swift`, use the package identity SwiftPM resolves from the chosen repository URL in each `.product(..., package: ...)` entry. The two backend repository names can therefore require different `package:` values even though both expose the `JsBaySDK` and `JsBayObjC` products.

`JsBaySDK` is the Swift façade for the public `jsbay.h` Value API. Add the packaged Swift package, create an `Engine` on the thread that will execute JavaScript, and keep all `Value` operations on that same thread. The SDK attaches its automatic driver to that thread's `CFRunLoop`; JavaScript timers run when the host runs that loop and applications never call `tick` or compute deadlines. `runLoop()` temporarily uses the core blocking loop and restores the automatic driver when it returns. `stopLoop()` and `requestInterrupt()` are safe from another thread.

### Owner thread and multi-instance hosts

Create one `Engine` per instance id on a **dedicated** thread with its own run loop. Do not attach many engines to the process main run loop: that schedules JavaScript on the UI/main thread.

By default, `Engine(id:)` and `[[JSBayEngine alloc] initWithIdentifier:error:]` refuse to attach when `CFRunLoopGetCurrent()` is the process main run loop (`JSBAY_INVALID_ARGUMENT` / `JsBayStatus.invalidArgument`). Opt in only when you intentionally own that risk via `allowMainRunLoopAttach: true` / `allowMainRunLoopAttach:YES`. `runLoop()` likewise refuses the process main thread without that opt-in.

Preferred shape: start a dedicated thread, ensure it runs a `CFRunLoop`, construct the engine there, and keep all `Value` work on that owner thread.

```swift
// On a dedicated owner thread (not the process main thread):
let engine = try Engine(id: 1)
let answer = try engine.evaluate("({ answer: 42 })", filename: "boot.js")
let number = try answer.get("answer").number()
try answer.close()
try engine.close()
```

`Value` owns a native handle. Call `close()` on the owning thread when it is no
longer needed. `deinit` deliberately never calls into the engine, because ARC
may run it on an arbitrary thread. Values passed to a native callback are
borrowed for that callback only; call `retain()` before retaining one beyond
the callback. A callback may return any owned `Value`; the SDK gives the core a
separate retained reference, so the returned Swift wrapper remains usable.

JavaScript exceptions are thrown as `JsException` and retain the live thrown
`Value`; JavaScript can throw values other than `Error`. Other Swift errors
from a native callback become a JavaScript `Error` with the error description.
Every `JsBayError` exposes `statusCode`, with public `JsBayStatus` constants
that match the C ABI. This includes SDK preconditions: a closed Engine reports
`instanceNotFound`, a wrong thread reports `wrongThread`, and closed, foreign,
or expired Values report `staleValue`.

When an exception only needs display text, `try error.describeAndClose()` reads
and consumes its original value. It preserves embedded NUL and Unicode. If a
custom `toString` throws, it closes both values and returns `"JavaScript
exception"`. It still throws for wrong-thread, borrowed, and stale values so a
caller never mistakes a lifecycle failure for exception text. Objective-C has
the equivalent `JSBayDescribeAndCloseException(error, &error)` helper; it keeps
the original `NSError` and `JSBayExceptionValueKey` entry point available.

`Engine.CacheOptions` is optional. It records whether a call used a warm cache
in `didHit`; a cache read/write failure still evaluates the source once.

Objective-C hosts link the `JsBayObjC` product and import `JSBayObjC.h` (not `jsbay.h`; the ObjC umbrella uses a distinct filename so case-insensitive disks do not collide with the C ABI header). Its
`JSBayEngine` and `JSBayValue` expose the same synchronous owner-thread model
and explicit `close:` ownership. A native block returns a `JSBayValue` or sets
an `NSError`; to throw a live JavaScript value, put it in the error's
`JSBayExceptionValueKey`. Errors produced by JavaScript use that same key, so
callers can inspect the original thrown value rather than a stringified copy.
`NSError.code` uses the same status table. Engine and owned Value `close` are
idempotent; closing a borrowed callback Value is rejected as `INVALID_ARGUMENT`,
and the wrapper is `STALE_VALUE` after its callback returns.

Every SDK text input must be well-formed Unicode. Swift `String` already has
that invariant. Objective-C validates each `NSString` before it crosses the C
ABI and returns `JSBayErrorInvalidArgument` for an unpaired UTF-16 surrogate;
it never converts that input to an empty string or replaces it. This applies
to source, filenames, cache options, property keys, binding names, strings,
error messages, and JSON. JavaScript text returned from the engine is always
well-formed UTF-8; an unpaired JavaScript surrogate is represented as U+FFFD.

The XCFramework device slice supports iOS 13. The arm64 Simulator slice starts
at iOS 14 because that is the minimum runtime emitted by the Apple toolchain;
the x86_64 Simulator slice remains iOS 13. The packaging gate reads every
Mach-O member's actual deployment version before publishing the framework.

Objective-C callers create `JSBayEngine` with `initWithIdentifier:error:` and `JSBayCacheOptions` with `initWithDirectory:version:`. Values come from an engine; sync completions come from a sync starter block. These types disable inherited `init` and `new` because those methods cannot supply the required state.

`SyncCompletion` is a thread-safe, data-only token. A sync starter can hand it to a background queue to `resolveString` / `resolveBytes` / `reject` later (typed UTF-8 string or opaque bytes; not JSON-only). The starter's borrowed `Value` arguments still expire when the block returns.

From the repository root, run these checks before changing the Apple SDK:

```sh
bash scripts/quality/apple-style.sh check
bash scripts/quality/native-style.sh check
bash scripts/quality/apple-lint.sh
```

`make check CHECKS=native-format,apple-style,apple-lint` runs these checks through pawl. `make format PLATFORMS=apple` formats native and Swift sources. `apple-style.sh fix` formats every Swift SDK, manifest, and consumer file with official `swift-format` 6.3.0. Select the matching Xcode toolchain or set `SWIFT_FORMAT` to an executable with that exact version. `apple-style.sh self-test` verifies that lint rejects a malformed file and that formatting is idempotent. `native-style.sh fix` formats Objective-C and headers with the shared pinned ClangFormat configuration. `apple-lint.sh` compiles Swift in language mode 5, checks Objective-C with warnings treated as errors, and runs Clang's analyzer with findings treated as errors. It also verifies that all eight unsupported Objective-C `init`/`new` construction paths fail to compile.

## Building from this repository

From the repository root, `./build-apple.sh` produces the XCFramework. The default device and packaging backend is **jsc**. Override with a positional argument (`quickjs`, `quickjs_ng`, or `jsc`) or set `JSBAY_APPLE_BACKEND` (the env var wins when both are set). Example: `JSBAY_APPLE_BACKEND=quickjs ./build-apple.sh` or `./build-apple.sh quickjs_ng`.

`JSBAY_APPLE_SMOKE=simulator` builds and runs only the simulator slice for the machine's architecture. It skips the macOS slice, the device slice, the other simulator architecture, XCFramework assembly, and Swift package packaging. Release and the daily macOS job keep the full script. Set `JSBAY_IOS_SIM_UDID` to boot an existing simulator instead of creating one.

`JSBAY_SOURCE_ROOT`, when used by host or packaging scripts, must point at this repository root. Leave it unset when you run the in-tree scripts from that root; do not hard-code a machine-local path.

### arm64e-only iPhoneOS SDKs (Zig vs clang consumers)

On newer iPhoneOS SDKs whose `libobjc.A.tbd` lists only `arm64e-ios`, Zig 0.17 cannot link an `aarch64-ios` consumer against that TBD. `build-apple.sh` therefore **skips the Zig iOS consumer by default** and prints a `WARN`. That skip is expected success, not a build failure.

- **Clang consumers still count:** `link_consumer_probes` (clang) still run and must pass. Local and CI Apple builds are green when clang probes pass, even if the Zig iOS consumer was skipped.
- **Zig consumer optional on arm64e-only SDKs:** force it with `JSBAY_FORCE_IOS_ZIG_CONSUMER=1` (expect link failure until Zig supports the TBD), or skip explicitly with `JSBAY_SKIP_IOS_ZIG_CONSUMER=1`. Legacy `JS_BAY_*` names are accepted.
- **When Zig is required:** on SDKs that are not arm64e-only (or after FORCE succeeds), the Zig iOS consumer must pass like the clang probes.

Integrators should treat a Zig SKIP/`WARN` on arm64e-only SDKs as documented behavior, not as a broken checkout.

## Isolation and observability

Prefer `Engine.createOnBackground` (or your own dedicated thread + run loop) so JavaScript never owns the main/UI thread. `getMemoryUsage()`, `runGc()`, and `setEventHandler` are owner-thread reporting hooks. Same-process native faults still terminate the process; see `docs/host-isolation.md`.
