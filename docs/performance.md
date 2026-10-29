# Performance

Measure the public path when comparing user-visible work:

```sh
make benchmark-interop RUNNER=c_abi BACKEND=quickjs_ng
```

The command writes one JSON record with the source fingerprint, toolchain, host details, payload, warmup, iterations, and elapsed time.

## Public interop benchmarks

`make benchmark-interop` builds the selected public consumer in a temporary directory and prints one JSON record. It does not write to `zig-out`.

```sh
make benchmark-interop RUNNER=c_abi BACKEND=quickjs_ng
make benchmark-interop RUNNER=swift BACKEND=jsc
make benchmark-interop RUNNER=jvm_kotlin BACKEND=quickjs_ng
make benchmark-interop RUNNER=harmony_arkts_check BACKEND=quickjs_ng
```

Measured runners are `c_abi`, `csharp`, `jvm_kotlin`, `jvm_java`, `swift`, `objc`, and `harmony_host_napi`. `harmony_arkts_check` and `harmony_typescript_check` compile entry points without timing them. `bench/interop/run.sh` defines toolchain requirements and runner selection.

Each measured runner evaluates code, calls a host callback, converts JSON text, copies a 4 KiB buffer, and creates/evaluates/destroys an engine. A failed operation, invalid result, or unavailable required tool fails the command instead of emitting a partial record. JVM output is not an Android measurement, and the Node-hosted Harmony runner is not an ArkTS device measurement.

For engine-internal investigation, use `zig build bench -Dbackend=quickjs_ng -Doptimize=ReleaseFast`. It does not include C ABI or SDK conversion costs. To compare inspector build configurations, use `bash bench/measure-diagnostics.sh OUTPUT_DIRECTORY quickjs_ng`; it preserves commands, artifacts, and exit codes in `OUTPUT_DIRECTORY`.

Compare records produced on the same host with the same backend, optimization mode, runner, and payload. Time for a full operation cannot identify the cost of one internal step. Profile first, then validate a change through the same public operation.

## Bytecode cache policy

Cache entries are keyed by source, filename, caller version, and build fingerprint. The implementation has no directory quota or eviction policy; hosts should store entries in an app-private directory and remove obsolete versions according to their own storage policy. Cache read or write failures fall back to source execution. A cached script that throws must not be executed again as a fallback.
