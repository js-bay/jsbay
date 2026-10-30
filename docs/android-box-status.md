# Android Escargot / Hermes status

Current Android x86_64 spike status for Escargot and Hermes backends (NDK r27c, AVD `jsbay_api34`). Not a production packaging guide.

## Toolchain

| Piece | Location / note |
|-------|-----------------|
| JDK | Temurin 17 |
| NDK | r27c |
| SDK | emulator, platform-tools, `platforms;android-34`, `system-images;android-34;google_apis;x86_64` |
| AVD | `jsbay_api34` (Pixel 6 / API 34 x86_64) |
| Emulator | TCG (`-accel off`, `-gpu swiftshader_indirect`); hardware KVM may be unavailable depending on host group membership |

## Install prefixes (Android x86_64)

| Prefix | Role |
|--------|------|
| `vendor/escargot-android-{build,install}-x86_64` | Escargot + bridge; cmake `ESCARGOT_THREADING=ON`, `LIBICU=OFF` (runtime-icu-binder static) |
| `vendor/icu-{src,host-build-for-android,android-build-x86_64,android-prefix-x86_64}` | ICU for Hermes (host tools, then NDK cross) |
| `vendor/hermes-android-{build,install}-x86_64` | Hermes standalone (`libhermesvm` / `libhermes_bridge` / `libjsi`); not `HERMES_IS_ANDROID`/fbjni; host `hermesc` via `IMPORT_HOST_COMPILERS` |

Host `vendor/{escargot,hermes,icu}-install` trees are **linux glibc** — do not use them for Android links.

## Smoke status

| Backend | Zig library-only | NDK shared `.so` | Emulator C ABI evaluate (`1+2`) | `check-c-abi` |
|---------|------------------|------------------|----------------------------------|---------------|
| QuickJS | yes | yes | pass (`jsbay-qjs-android-smoke-ok`) | pass |
| Escargot | yes | yes (do not re-link `escargot_bridge.o`; already in the Zig archive) | pass (`jsbay-escargot-android-smoke-ok`) | pass |
| Hermes | yes | yes (push x86_64 `libc++_shared.so`, not i686) | pass (`jsbay-hermes-android-smoke-ok`) | pass |

`jsbay_engine_create_with_options` is force-exported from library-only builds via `@export` in `src/root.zig`. Zig 0.17 `process.run` does not PATH-search relative `cc`/`c++`; `tools/src/main.zig` `resolvePathCmd` uses absolute compiler paths for `check-c-abi`.

## Escargot Android link sketch

```bash
# Zig: -Dbackend=escargot -Dshared=false -Dlibrary-only=true -Dtarget=x86_64-linux-android.24
#      -Descargot-install=vendor/escargot-android-install-x86_64 -Dandroid-sysroot=… -Dlibstdcxx=libc++_static.a
# NDK: clang++ -shared -Wl,--whole-archive libjsbay.a -Wl,--no-whole-archive \
#      libescargot.a libgc-lib.a liblibbf.a liblibsimdutf.a libruntime-icu-binder-static.a \
#      -static-libstdc++ libatomic.a -llog -lm -ldl
```

## Hermes Android link sketch

```bash
# Zig: -Dbackend=hermes -Dshared=false -Dlibrary-only=true -Dtarget=x86_64-linux-android.24
#      -Dhermes-install=vendor/hermes-android-install-x86_64 -Dicu-lib-dir=vendor/icu-android-prefix-x86_64/lib
# NDK: clang++ -shared -Wl,--whole-archive libjsbay.a -Wl,--no-whole-archive \
#      -lhermes_bridge -lhermesvm -ljsi -static-libstdc++ -llog -lm -ldl
# Device: LD_LIBRARY_PATH must include libhermes_{bridge,vm}.so, libjsi.so, libc++_shared.so
```

## Remaining

- Full gated `unit_tests` on the TCG emulator: not run (too heavy). Host linux gated counts: see `docs/capability.md` / `docs/production-gaps.md`.
- aarch64 Android engine prefixes + device smoke: not built.
- Optional: single `build-android-{escargot,hermes}.sh` encoding stub dirs and link lines.
