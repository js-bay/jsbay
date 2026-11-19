# Android `unit_tests` (official device build)

Zig does not ship Android libc. The scripts under `scripts/android-unit-tests/` provide an NDK libc description, CRT overlay and Bionic library stubs to the explicit `android-test-compile` build step.

1. Compile the same official test module with `-Dandroid-test-libc` and `-Dandroid-test-libdir`; these options must be paired and are rejected for non-Android targets.
2. Emit a dynamically linked PIE using the device linker, rather than parsing and replaying an intentionally failed compiler command.
3. Use the in-tree device test runner supporting `--list`, `--test-filter=`, `--isolate` (fork), and `--timeout=`.
4. Push the ELF **and** `docs/state-tcas-*.md` to the device (a missing picture lock is reported as `PictureDrift`, not a distinct I/O error).

The Android-only options affect the test artifact, not production library linkage or test assertions. This is **x86_64** emulator verification, not ARM64 hardware.

## Escargot emutls

Android Escargot objects use emulated TLS (`__emutls_*`). Zig’s compiler-rt `__emutls_get_address` is not ABI-safe with Clang-generated `__emutls_v` objects: the same Zig objects plus `libescargot.a` can create/destroy successfully when finally linked by NDK clang++ (LLVM emutls) and SIGSEGV in `ThreadLocal::emptyString` when finally linked by `zig test` (Zig emutls).

The Escargot test build therefore links NDK `libclang_rt.builtins-x86_64-android`, sets `bundle_compiler_rt = false`, and adds `scripts/android-unit-tests/zig_probe_stack_x86_64.S` for the only remaining Zig compiler-rt symbol (`__zig_probe_stack`). This is a **unit_tests ELF** link workaround, not a sanitizer disable, and not a change to the NDK-linked product `.so`.

## Runner compatibility

Per-test timeouts use an elapsed monotonic deadline, not a count of sleep calls, so scheduling stalls cannot multiply the configured timeout. A failed fork is a failure rather than an unbounded in-process fallback.

Some API24 x86_64 images expose legacy fixed negative VDSO virtual addresses through Bionic `dl_iterate_phdr`; Zig's checked ELF unwinder otherwise overflows while recording an expected allocation failure. The Android test artifact includes `android_phdr_compat.c`, which normalizes only that legacy VDSO header view and its compensating load bias together, preserving every mapped NOTE and unwind address. Production libraries are unchanged; overflow checks, OOM assertions and sanitizer settings remain enabled.

## Environment

Set toolchain paths in the environment; do not hard-code workstation prefixes.

| Variable | Role |
| --- | --- |
| `ANDROID_NDK_HOME` | Required. NDK root (e.g. r28c). |
| `ANDROID_API` | Default `24` (link API). |
| `ANDROID_ABI` | Must be `x86_64`. |
| `ANDROID_NDK_HOST_PREBUILT` | Default `linux-x86_64`. |
| `ANDROID_UNIT_TEST_OUT` | Use separate directories for concurrent API levels. Generated libc file, stubs, CRT overlay, ELFs, logs. Default: `$REPO/.zig-cache/android-unit-tests`. |
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

# Build the pinned Escargot prefix and current bridge first.
scripts/rebuild-escargot-android-install.sh

# Cross-compile on the host; this does not execute tests.
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
