# Test entry points

`src/tests/` exercises engine internals and is collected by `src/tests/all_tests.zig`. This directory tests external consumers, SDKs, release tools, and command-line drivers. Independent package tests stay with their package under `libs/`.

- Run engine and package tests with `zig build test -Dbackend=quickjs_ng --summary all`.
- Run the repository's tooling checks through the normal build and quality targets.
- [Inspector E2E](inspector/e2e.cjs) requires a running Inspector demo; pass its port with `--port`.
- [Test262](test262/run.sh) and [upstream regressions](qjs-regression/run.sh) own their manifests and drivers.
- [C consumers](run-value-consumers.sh) compile and execute against an installed core archive.
- [Process isolation](process-isolation/run.sh) proves Zig/native abort kills only a child process (test-only `-Dfault-injection`). Also: [Android device](android-sdk/run-process-isolation-device.sh), [iOS Simulator](apple-sdk/run-process-isolation-sim.sh), [Harmony device](harmony-sdk/run-process-isolation-device.sh).
- [The idle-wake driver](host_wake_consumer.mjs) accepts a compiled [C host](host_wake_consumer.c) executable and verifies an Inspector request wakes an otherwise idle owner. It requires Node.js with a global `WebSocket` implementation.
- [Owner-thread inspector embed smoke](debug_owner_embed_consumer.c) keeps create/inspector/`run_loop`/destroy on one pthread; the launcher only `stop_loop`. Prefer `zig build debug-owner-embed-test -Dbackend=quickjs_ng` for the example binary.

See [CI checks](../docs/testing.md#ci) for automation and [the API contract](../docs/api-contract.md) for behavior these tests protect.
