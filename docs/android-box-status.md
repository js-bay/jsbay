# Android Escargot / Hermes support

Current constraints and reproducible verify steps for Escargot and Hermes on Android x86_64 (NDK r27c, AVD `jsbay_api34`). Not a production packaging guide.

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

## Constraints

- Spike support targets Android **x86_64** API 24+ with the NDK prefixes above; aarch64 Android engine prefixes are out of scope for this document.
- Product packaging (AAR / multi-ABI) is separate; this page covers library-only Zig archives plus NDK shared objects linked from those archives.
- Escargot NDK links must not re-link `escargot_bridge.o` (already in the Zig archive).
- Hermes device/emulator `LD_LIBRARY_PATH` must include x86_64 `libhermes_{bridge,vm}.so`, `libjsi.so`, and x86_64 `libc++_shared.so` (not an i686 copy).
- `jsbay_engine_create_with_options` is force-exported from library-only builds via `@export` in `src/root.zig`.
- Zig 0.17 `process.run` does not PATH-search relative `cc`/`c++`; `tools/src/main.zig` `resolvePathCmd` uses absolute compiler paths for `check-c-abi`.
- Full gated `unit_tests` on a TCG emulator is not part of the smoke path; host linux gated counts live in `docs/capability.md` / `docs/production-gaps.md`.

## Verify (smoke)

Build a library-only archive, NDK-link a shared object, push it to the AVD, and evaluate a trivial script through the C ABI (for example `1+2`). Then run host `check-c-abi` against the same ABI surface.

```bash
# Escargot Zig archive (paths relative to repo root; set android-sysroot to the NDK sysroot):
# zig build -Dbackend=escargot -Dshared=false -Dlibrary-only=true -Dtarget=x86_64-linux-android.24 \
#   -Descargot-install=vendor/escargot-android-install-x86_64 -Dandroid-sysroot=… -Dlibstdcxx=libc++_static.a

# Hermes Zig archive:
# zig build -Dbackend=hermes -Dshared=false -Dlibrary-only=true -Dtarget=x86_64-linux-android.24 \
#   -Dhermes-install=vendor/hermes-android-install-x86_64 -Dicu-lib-dir=vendor/icu-android-prefix-x86_64/lib \
#   -Dandroid-sysroot=… -Dlibstdcxx=…

# After NDK link + adb push, confirm evaluate works; on the host:
# zig build tool -- check-c-abi …
```

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
