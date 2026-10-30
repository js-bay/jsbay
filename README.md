<p align="center">
  <img src="./assets/banner.svg" alt="JS Bay — Embed JavaScript engines" width="820">
</p>

# JS Bay

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig 0.17](https://img.shields.io/badge/Zig-0.17-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)

JS Bay embeds JavaScript with a Zig package and a stable typed C ABI. Backends are selected at build time; hosts keep one instance/value/timer/callback model. SDKs wrap that ABI on Android, Apple, .NET, and Harmony.

Product defaults: Apple packages default to JavaScriptCore (`jsc`); Android, Harmony, and desktop Zig builds default to classic QuickJS (`quickjs`). QuickJS-NG (`quickjs_ng`) remains an optional alternative. JavaScriptCore is available only on Apple targets.

The library is aimed at high-performance embedding and the same C surface across desktop and mobile.

This project is experimental. Public APIs may change substantially between releases.

## Minimum supported versions

Floors come from SDK manifests and packaging gates, not CI host images.

| Surface | Minimum |
| --- | --- |
| iOS (device) | 13.0 |
| iOS Simulator | arm64 14.0 · x86_64 13.0 |
| macOS | 11.0 |
| Android | API 24 (7.0) |
| HarmonyOS / OpenHarmony | API 12 |
| .NET | `net8.0` |

Linux desktop packages have no documented OS floor. Windows desktop packages are not published yet.

Platform SDK READMEs spell out the same floors next to their packaging gates: [Apple](sdk/apple/README.md) (device iOS 13 · arm64 Simulator 14), [Android](sdk/android/README.md) (`minSdk` / `ANDROID_API_LEVEL` 24), and [Harmony](sdk/harmony/README.md) (API 12 compatible · default fixture target API 20).

## Quick start

Use Zig 0.17 and clone QuickJS submodules:

```sh
git submodule update --init --recursive
zig build -Dbackend=quickjs
zig build test
```

Supported backend tags are `quickjs`, `quickjs_ng`, and `jsc`. Defaults: Apple packaging uses `jsc`; other product builds use `quickjs`. Pass `-Dbackend=quickjs_ng` or `-Dbackend=jsc` when you want those variants. Pack several engines with `-Dbackends=` (comma-separated; first is primary; create-time select, not hot-switch) — see [backend selection](docs/embedding.md#backend-selection). Apple packaging also accepts `JSBAY_APPLE_BACKEND` (see [Apple SDK](sdk/apple/README.md)); set `QUICKJS_BACKEND` for Android / Harmony packaging scripts.

The public C header is [`include/jsbay.h`](include/jsbay.h). Create and use each engine on one owner thread, release every owned `jsbay_value_t`, and destroy the engine on that same thread. `jsbay_engine_request_interrupt` and `jsbay_engine_stop_loop` are the ordinary cross-thread controls.

```c
#include "jsbay.h"

int main(void) {
    const uint8_t source[] = "1 + 2";
    const uint8_t filename[] = "app.js";
    jsbay_value_t value = 0;
    jsbay_value_t exception = 0;

    if (!jsbay_engine_create(1, NULL, NULL)) return 1;
    jsbay_status_t status = jsbay_engine_evaluate(
        1,
        (jsbay_utf8_t){source, sizeof(source) - 1},
        (jsbay_utf8_t){filename, sizeof(filename) - 1},
        NULL, &value, &exception);
    if (status == JSBAY_OK) jsbay_value_release(value);
    if (status == JSBAY_EXCEPTION) jsbay_value_release(exception);
    jsbay_engine_destroy(1);
    return status == JSBAY_OK ? 0 : 1;
}
```

After `zig build -Dbackend=quickjs`, link the installed static library (on macOS with `-Dbackend=jsc`, also link Foundation and JavaScriptCore):

```sh
cc -std=c11 -Iinclude hello.c zig-out/lib/libjsbay.a -lm -pthread -o hello
```

The JavaScript event loop owns its monotonic clock, timers, waiting, and wakeups. Call `jsbay_engine_run_loop` on a dedicated owner thread, or let the SDK connect it to the platform owner thread. `jsbay_engine_stop_loop` is thread-safe. Each queued JavaScript task finishes with a microtask checkpoint; callers do not supply timestamps or compute deadlines.

## Consuming release artifacts

GitHub Releases publish versioned archives. Match OS, architecture, and backend.

Packaging scripts resolve the repository from their own location. Prefer an explicit override such as `JSBAY_SOURCE_ROOT` only when the checkout is not next to the script; do not hardcode a developer machine path.

| Surface | Backends | Artifact | In GitHub Release |
| --- | --- | --- | --- |
| Desktop static library | Linux: `quickjs`, `quickjs_ng` · macOS: `quickjs`, `jsc`, `quickjs_ng` | `jsbay-<ver>-<os>-<arch>-<backend>.tar.gz` (`lib/libjsbay.a`, `include/`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, `VERSION`, `COMMIT`, `backend`) | Yes |
| Apple XCFramework / SwiftPM | `jsc` (default), `quickjs`, `quickjs_ng` | `jsbay-<ver>-apple-<backend>-JsBay.xcframework.zip` | Yes |
| Android Maven / AAR / jniLibs | `quickjs` (default), `quickjs_ng` | `jsbay-<ver>-android-<backend>-maven.zip`, `jsbay-<ver>-android-<backend>.aar`, `jsbay-<ver>-android-jniLibs-<backend>.tar.gz` | Yes |
| Harmony HAR | `quickjs` (default), `quickjs_ng` | `jsbay-<ver>-harmony-<backend>-arm64-v8a.har` | No — local staging only |
| Source snapshot | — | `jsbay-<ver>-source.tar.gz` | Yes |

Windows desktop packages are not in Release yet. `jsc` is Apple-only.

### Desktop (C / Zig)

Unpack the tarball and point your build at `include/` and `lib/libjsbay.a`. Zig packages can also depend on this repository via `build.zig.zon` and build with `-Dbackend=…`.

### Apple

Each zip is a Git-ready Swift package (one backend). Extract the top-level directory, publish it as its own Git repository, tag it, and add that URL in Xcode. Distinct backends need distinct repository URLs.

### Android

Host one maven zip as a Maven repository root and depend on `implementation("io.jsbay:js-bay-android:<ver>")`. Each zip embeds one backend under the same coordinates, so do not merge two backend zips into one Maven root. The standalone `.aar` and the `jniLibs` tarball are for manual / NDK integration.

### Harmony

Requires a DevEco host. Build an OpenHarmony `libjsbay.a` for the chosen backend, then:

```sh
export DEVECO_SDK_HOME=… HVIGORW=… OHPM=… JSBAY_LIBRARY=…/libjsbay.a
# defaults to classic quickjs; set QUICKJS_BACKEND=quickjs_ng for NG
scripts/stage-harmony-har.sh /tmp/jsbay-harmony 0.1.0
```

GitHub-hosted runners do not yet have a verified DevEco SDK 12 / Hvigor / ohpm path, so Release automation does not upload HARs.

## SDKs and integration

The Android, Apple, .NET, and Harmony SDKs wrap the same typed C ABI. Installation and platform build details are in their SDK directories.

- [Android](sdk/android)
- [Apple](sdk/apple)
- [.NET](sdk/dotnet)
- [Harmony](sdk/harmony)

Read [the API contract](docs/api-contract.md) before implementing a binding or callback. It defines value ownership, errors, thread affinity, callbacks, cache behavior, and the optional synchronous-native extension. [Embedding](docs/embedding.md) gives the lifecycle checklist.

## Documentation

Start with the [documentation index](docs/readme.md). The most commonly needed guides are [embedding](docs/embedding.md), [runtime limits](docs/runtime-limits.md), [backend selection](docs/embedding.md#backend-selection), and [Inspector setup](docs/inspector.md).

## License

JS Bay is licensed under the [MIT License](LICENSE). Bundled artifacts and source releases include [third-party notices](THIRD_PARTY_NOTICES.md). Platform marks in `assets/banner.svg` are documented under [brand icon attribution](assets/brand-icons/ATTRIBUTION.md) (including CC BY 3.0 for the Android robot).

See also [SECURITY.md](SECURITY.md) for vulnerability reporting and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards. Contribution workflow is in [CONTRIBUTING.md](CONTRIBUTING.md).
