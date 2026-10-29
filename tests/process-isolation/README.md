# Process isolation harness

Proves that an intentional Zig/native fault in `libjsbay` kills **only** a child
process when the engine is out-of-process. Same-process hosts are still not
isolated (see `docs/host-isolation.md`).

## Host (Linux / macOS)

```sh
bash tests/process-isolation/run.sh
```

## Android device (Zig abort ≠ parent death)

Builds a **test-only** fault-injection `libjsbay.so` into a separate output dir
(never publish `build-android/jniLibs`), links `harness.c`, pushes to the phone,
runs parent/child via `/data/local/tmp`.

```sh
ADB=/path/to/adb ADB_SERVER_PORT=5037 ANDROID_HOME=/path/to/sdk \
  ANDROID_SERIAL=<device-serial> \
  bash tests/android-sdk/run-process-isolation-device.sh
```

Optional: `SKIP_FAULT_BUILD=1` reuses an existing fault `.so` under
`JSBAY_ANDROID_FAULT_OUT` (default `/tmp/jsbay-android-fault-injection/jniLibs`).

## iOS Simulator

```sh
JSBAY_IOS_SIM_UDID=<booted-simulator-udid> \
  bash tests/apple-sdk/run-process-isolation-sim.sh
```

Does **not** use `-Dapple-package` (incompatible with fault-injection by design).

## Harmony device

```sh
HDC=/path/to/hdc HDC_SERIAL=<device-serial> OHOS_SDK_NATIVE=/path/to/ohos-sdk/native \
  bash tests/harmony-sdk/run-process-isolation-device.sh
```

Builds/links/pushes an OHOS ELF. Shell exec may **SKIP** under SELinux without a HAP.

## Rules

Requires `-Dfault-injection=true` for the child-linked archive/`.so`. That option is
default OFF and must never be used by publish scripts (`build-android.sh`,
`build-apple.sh` / `-Dapple-package`).

## Extreme modes (test-only fault-injection)

```bash
# Host: baseline + 20 harness loops + abort×32/segfault×32 + parallel abort×24
bash tests/process-isolation/run-extreme-host.sh

# Harness CLI (linked against -Dfault-injection=true):
./process_isolation_harness                  # abort + segfault + healthy
./process_isolation_harness --storm 32       # sequential storms
./process_isolation_harness --storm-parallel 24
```

Publish builds must leave `-Dfault-injection` OFF. Device extreme runners:
`tests/android-sdk/run-extreme-device.sh`, `tests/apple-sdk/run-extreme-sim.sh`,
`tests/harmony-sdk/run-extreme-hap.sh`.
