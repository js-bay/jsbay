# Android on this Linux box (spike notes)

Updated: 2026-10-31 02:49 Asia/Shanghai (CST).

## Toolchain present

- JDK: `/home/box/jdk` (Temurin 17)
- NDK: `/home/box/android-ndk-r27c`
- SDK: `/home/box/android-sdk` — emulator, platform-tools, `platforms;android-34`, `system-images;android-34;google_apis;x86_64`
- AVD: `jsbay_api34` (Pixel 6 / API 34 x86_64)
- Host helpers: `/tmp/make-4.4.1/make`, `/home/box/.local/bin/c++` → gcc-root g++-14, `LD_LIBRARY_PATH` for pkg-config (`libpkgconf`) when Zig build probes packages

## Emulator

- `/dev/kvm` exists but group is `pulse-access`; user `box` is not in it → **no hardware accel**.
- Works: `emulator -avd jsbay_api34 -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -accel off`
- TCG boot is slow; `adb` reaches `emulator-5554` and can push/run native binaries before `sys.boot_completed=1`.

## Prefixes (Android x86_64)

| Prefix | Role |
|--------|------|
| `vendor/escargot-android-{build,install}-x86_64` | Escargot + bridge; cmake `ESCARGOT_THREADING=ON`, `LIBICU=OFF` (runtime-icu-binder static) |
| `vendor/icu-{src,host-build-for-android,android-build-x86_64,android-prefix-x86_64}` | ICU for Hermes (host tools then NDK cross) |
| `vendor/hermes-android-{build,install}-x86_64` | Hermes standalone (`libhermesvm`/`libhermes_bridge`/`libjsi`); **not** `HERMES_IS_ANDROID`/fbjni; host `hermesc` via `IMPORT_HOST_COMPILERS` |

Host `vendor/{escargot,hermes,icu}-install` remain **linux glibc** — do not use them for Android links.

## QJS `js_bay` on Android — PASS

1. Zig: `-Dbackend=quickjs -Dshared=false -Dlibrary-only=true -Dtarget=x86_64-linux-android.24` with `-Dandroid-sysroot=$NDK/.../sysroot` and stub `lib{m,pthread,dl,rt,gcc_s}.a` dir.
2. NDK link: `clang -shared -Wl,-soname,libjs_bay.so -Wl,--whole-archive libjs_bay.a -Wl,--no-whole-archive -llog -lm -lc++_static -lc++abi`
3. AVD: C smoke `js_bay_engine_create` + `js_bay_engine_evaluate("1+2")` → `jsbay-qjs-android-smoke-ok`.

## Escargot Android — PASS (evaluate smoke)

### Zig library-only

```bash
export LD_LIBRARY_PATH="/home/box/.local/icu-root/usr/lib/x86_64-linux-gnu:/home/box/.local/lib"
NDK=/home/box/android-ndk-r27c
NDK_BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
NDK_SYSROOT=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot
API=24
LIBCXX=$NDK_SYSROOT/usr/lib/x86_64-linux-android/libc++_static.a
LIBATOMIC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux/x86_64/libatomic.a
# STUB = dir of empty NDK-built lib{m,pthread,dl,rt,gcc_s}.a (Zig link probe)
zig build -Dbackend=escargot -Dshared=false -Doptimize=ReleaseFast -Dlibrary-only=true \
  --prefix "$PREFIX_ESC" \
  -Dandroid-sysroot="$NDK_SYSROOT" -Dandroid-lib-dir="$STUB" \
  -Dtarget=x86_64-linux-android.${API} \
  -Descargot-install=vendor/escargot-android-install-x86_64 \
  -Dlibstdcxx="$LIBCXX"
```

### NDK shared lib (do **not** re-link `escargot_bridge.o` — already inside Zig `.a`)

```bash
ESC=vendor/escargot-android-install-x86_64/lib
"$NDK_BIN/x86_64-linux-android${API}-clang++" -shared -o /tmp/libjs_bay_escargot.so \
  -Wl,-soname,libjs_bay.so \
  -Wl,--whole-archive "$PREFIX_ESC/lib/libjs_bay.a" \
  "$ESC/libescargot.a" "$ESC/libgc-lib.a" "$ESC/liblibbf.a" \
  "$ESC/liblibsimdutf.a" "$ESC/libruntime-icu-binder-static.a" \
  -Wl,--no-whole-archive -static-libstdc++ "$LIBATOMIC" -llog -lm -ldl
```

### Device smoke

```bash
adb -s emulator-5554 push /tmp/libjs_bay_escargot.so /data/local/tmp/libjs_bay.so
adb -s emulator-5554 push /tmp/jsbay_smoke_escargot /data/local/tmp/
adb -s emulator-5554 shell 'cd /data/local/tmp; LD_LIBRARY_PATH=/data/local/tmp ./jsbay_smoke_escargot'
# → jsbay-escargot-android-smoke-ok  (ESC_RC=0)
```

## Hermes Android — PASS (evaluate smoke)

### Zig library-only

```bash
zig build -Dbackend=hermes -Dshared=false -Doptimize=ReleaseFast -Dlibrary-only=true \
  --prefix "$PREFIX_HER" \
  -Dandroid-sysroot="$NDK_SYSROOT" -Dandroid-lib-dir="$STUB" \
  -Dtarget=x86_64-linux-android.${API} \
  -Dhermes-install=vendor/hermes-android-install-x86_64 \
  -Dicu-lib-dir=vendor/icu-android-prefix-x86_64/lib \
  -Dlibstdcxx="$LIBCXX"
```

### NDK shared lib

```bash
"$NDK_BIN/x86_64-linux-android${API}-clang++" -shared -o /tmp/libjs_bay_hermes.so \
  -Wl,-soname,libjs_bay.so \
  -Wl,--whole-archive "$PREFIX_HER/lib/libjs_bay.a" -Wl,--no-whole-archive \
  -L vendor/hermes-android-install-x86_64/lib -lhermes_bridge -lhermesvm -ljsi \
  -Wl,-rpath,/data/local/tmp -static-libstdc++ -llog -lm -ldl
```

### Device smoke (push **x86_64** `libc++_shared.so`, not i686)

```bash
HLIB=vendor/hermes-android-install-x86_64/lib
CXX64=$NDK_SYSROOT/usr/lib/x86_64-linux-android/libc++_shared.so
adb -s emulator-5554 push /tmp/libjs_bay_hermes.so /data/local/tmp/libjs_bay.so
adb -s emulator-5554 push $HLIB/libhermes_{bridge,vm}.so $HLIB/libjsi.so "$CXX64" /data/local/tmp/
# rename: libc++_shared.so must be the basename on device
adb -s emulator-5554 push "$CXX64" /data/local/tmp/libc++_shared.so
adb -s emulator-5554 push /tmp/jsbay_smoke_hermes /data/local/tmp/
adb -s emulator-5554 shell 'cd /data/local/tmp; LD_LIBRARY_PATH=/data/local/tmp ./jsbay_smoke_hermes'
# → jsbay-hermes-android-smoke-ok  (HER_RC=0)
```

## `check-c-abi` / host-cc

- Zig 0.17 `process.run` does **not** PATH-search relative `cc`/`c++`.
- Fixed in `tools/src/main.zig` `resolvePathCmd`: absolute `/usr/bin/cc` and `/home/box/.local/bin/c++`.
- `js_bay_engine_create2` was tree-shaken from library-only builds; forced with `@export(&c_api_impl.js_bay_engine_create2, .{ .name = "js_bay_engine_create2" })` in `src/root.zig`.
- Verified 2026-10-31:

```bash
unset LD_LIBRARY_PATH   # avoid host cc picking wrong libs
zig build tool -- check-c-abi /tmp/libjs_bay_escargot.so --nm "$NDK_BIN/llvm-nm"   # exit 0
zig build tool -- check-c-abi /tmp/libjs_bay_hermes.so --nm "$NDK_BIN/llvm-nm"     # exit 0
```

`build-android.sh` may still need `LD_LIBRARY_PATH` for pkg-config when Zig configures; prefer exporting the icu-root + `.local/lib` paths before the script, and absolute NDK `llvm-nm` for ABI check.

## Not done / remaining blockers

- Full gated `unit_tests` on TCG emulator: **not** run (too heavy); host linux gated still: Hermes ~532 pass / Escargot ~491 pass (see adversarial review).
- aarch64 Android engine prefixes + device smoke: not rebuilt this pass (x86_64 AVD first).
- Packaging a single `build-android-{escargot,hermes}.sh` that encodes the stub dir + link lines above: optional follow-up.
- `/dev/kvm` for box user still blocked by group membership.
