# jsbay CrashIsolation HAP

Device Ability that runs `tests/harmony-sdk/CrashIsolation.ets` (+ Worker) against
the Harmony SDK HAR on a physical device.

## Prerequisites

Export DevEco / OHOS toolchain paths for your machine (do not hard-code them in
the repo):

```bash
export PATH="$DEVECO_NODE_BIN:$PATH"   # DevEco tools/node/bin
export NODE_HOME=...                  # DevEco tools/node
export DEVECO_SDK_HOME=...            # DevEco Contents/sdk
export NODE_PATH=...                  # optional ohpm global modules
export OHOS_SYSROOT=...               # ohos-sdk native sysroot
export HVIGORW=...                    # hvigorw
export OHPM=...                       # ohpm
```

Copy `local.properties.example` → `local.properties` and point `sdk.dir` at your
DevEco SDK. Configure signing in DevEco (Project Structure → Signing Configs);
never commit cert/keystore paths or passwords into `build-profile.json5`.

## Build / run

```bash
bash tests/harmony-sdk/build-crash-isolation-hap.sh
HDC=/path/to/hdc HDC_SERIAL=<device-serial> bash tests/harmony-sdk/run-extreme-hap.sh
```

Hilog markers: `JSBAY_CRASHISO_PASS`, `PASS: harmony crash-isolation harness complete`.

The product HAP must not export the test-only `-Dfault-injection` symbol; the
probe Ability logs `JSBAY_PROBE_SKIP` when that symbol is absent.
