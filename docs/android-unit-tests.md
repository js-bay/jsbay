# Android `unit_tests` (official device replay)

Zig 0.17 cannot provide libc for `x86_64-linux-android.*`, so `zig build test-compile` does not by itself emit a device ELF. The scripts under `scripts/android-unit-tests/` are the official, in-tree way to:

1. Probe the official `test-compile` command (expected to fail with “unable to provide libc”).
2. Replay that exact `zig test` line with an NDK `--libc` file, CRT name overlay, and emit-bin.
3. Use a device test runner that supports `--list`, `--test-filter=`, `--isolate` (fork), and `--timeout=`.
4. Push the ELF **and** `docs/state-tcas-*.md` to the device (a missing picture lock is reported as `PictureDrift`, not a distinct I/O error).

This path does **not** change production `build.zig` or test assertions. It is **x86_64** emulator verification, not ARM64 hardware.

## Escargot emutls

Android Escargot objects use emulated TLS (`__emutls_*`). Zig’s compiler-rt `__emutls_get_address` is not ABI-safe with Clang-generated `__emutls_v` objects: the same Zig objects plus `libescargot.a` can create/destroy successfully when finally linked by NDK clang++ (LLVM emutls) and SIGSEGV in `ThreadLocal::emptyString` when finally linked by `zig test` (Zig emutls).

The Escargot replay therefore links NDK `libclang_rt.builtins-x86_64-android`, passes `-fno-compiler-rt`, and adds `scripts/android-unit-tests/zig_probe_stack_x86_64.S` for the only remaining Zig compiler-rt symbol (`__zig_probe_stack`). This is a **unit_tests ELF** link workaround, not a sanitizer disable, and not a change to the NDK-linked product `.so`.

## Environment

Set toolchain paths in the environment; do not hard-code workstation prefixes.

| Variable | Role |
| --- | --- |
| `ANDROID_NDK_HOME` | Required. NDK root (e.g. r28c). |
| `ANDROID_API` | Default `24` (link API). |
| `ANDROID_ABI` | Must be `x86_64`. |
| `ANDROID_NDK_HOST_PREBUILT` | Default `linux-x86_64`. |
| `ANDROID_UNIT_TEST_OUT` | Generated libc file, stubs, CRT overlay, ELFs, logs. Default: `$REPO/.zig-cache/android-unit-tests`. |
| `ANDROID_SERIAL` | Preferred device (avoid picking a second emulator). |
| `HERMES_ANDROID_PREFIX` / `ICU_ANDROID_PREFIX` | Hermes + ICU Android prefixes. Default under `vendor/…-x86_64`. |
| `ESCARGOT_ANDROID_PREFIX` | Escargot Android prefix. Default `vendor/escargot-android-install-x86_64`. |
| `UNIT_TEST_ARGS` | Host-side extra argv (for example `--test-filter='…'`). For an official unfiltered run use `env -u UNIT_TEST_ARGS`. |
| `UNIT_TEST_BIN` / `UNIT_TEST_LOG` | Optional override of the ELF and log path. |

Do not export Linux glibc `HERMES_INSTALL` / `ICU_PREFIX` / `ESCARGOT_INSTALL` into this path. The compile script unsets them.

## Commands

```bash
export ANDROID_NDK_HOME=…/ndk/28.2.13676358   # your NDK
# Optional: export ANDROID_UNIT_TEST_OUT=/path/to/writable/out

# Compile (host). Escargot needs a prebuilt Android prefix.
scripts/android-unit-tests/compile.sh quickjs
scripts/android-unit-tests/compile.sh quickjs_ng
scripts/android-unit-tests/compile.sh hermes
scripts/android-unit-tests/compile.sh escargot

# Device (x86_64 emulator, abi checked). Filter values that contain spaces
# must be quoted inside UNIT_TEST_ARGS so the remote shell keeps them intact.
export ANDROID_SERIAL=emulator-5554
env -u UNIT_TEST_ARGS scripts/android-unit-tests/run-device.sh quickjs
UNIT_TEST_ARGS="--test-filter='close between reserve and commit'" \
  scripts/android-unit-tests/run-device.sh escargot 180 420
```

Compile is not a pass. Device `run_exit=0` with the printed `passed` / `failed` / `crash` / `timeout` counts is the result. One crash is isolated; it does not abort the rest of the suite.
