# Harmony device benchmark entry

`ArkTSInteropBenchmark.ets` is a device-facing entry point. Call
`runArkTSInteropBenchmark` on the Worker that owns `Engine`, passing a
monotonic nanosecond clock supplied by the application. It deliberately does
not write the host JSON schema and must not be labelled as a host result.

The return value contains the five public-facade workloads. A device harness
adds device model, OS, SDK/build version, backend, and clock implementation to
its own result record. The device must use one Engine-owner Worker for the
whole call. `make benchmark-interop RUNNER=harmony_arkts_check` only checks
the entry with the configured OpenHarmony SDK compiler; it does not measure a
device. It requires an internally matching DevEco toolchain supplied through
`DEVECO_SDK_HOME`, `OHPM`, `HVIGORW`, and `NODE_PATH`, plus an OpenHarmony
archive in `JSBAY_HARMONY_ARCHIVE`. `HVIGORW` is the matching Hvigor
entry point (the official executable wrapper or its JavaScript entry). For an API 12 SDK the check uses its temporary
`5.0.0(12)` target variant by default; set `HARMONY_TARGET_SDK_VERSION` to
select another installed target. The check builds with a temporary benchmark
fixture, removes it before the final HAR package, and never treats
TypeScript-only checking as ArkTS validation.
