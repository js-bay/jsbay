# JS Bay Node.js SDK

The Node.js SDK loads JsBay through Node-API. `Engine` is thread-affine: create, evaluate, bind, and close it on the same JavaScript thread. Each engine attaches to the Node.js event loop. Explicitly close engines when their work is complete; garbage collection and environment cleanup provide fallback disposal.

`bind` exposes a synchronous host callback. `bindAsync` returns a guest Promise and accepts a host value, Promise, or thenable. Native Promise creation and settlement use the [public asynchronous C ABI](../../docs/native-async.md). `evaluate` copies a synchronous result and rejects Promise results; `evaluateAsync` returns a Node.js Promise and waits for guest thenables. The SDK does not inject JavaScript source or a request table into the guest.

## Build

Build a compatible archive from the repository root, then build the addon with CMake. `NODE_INCLUDE` must contain `node_api.h` and `uv.h` for the target Node.js or Electron installation. The Windows release workflow builds the QuickJS-NG x64 package and verifies its npm installation and Electron loading; Windows support depends on those workflow checks.

Requirements are the repository's Zig toolchain, CMake, a C++17 compiler, and matching Node.js or Electron development headers. Set `NODE_INCLUDE` to the directory containing those headers. If Node.js headers are installed alongside its executable, `NODE_INCLUDE="$(node -p 'require("node:path").resolve(process.execPath, "../../include/node")')"` locates that directory; verify that both header files exist before building. An explicit header directory is needed when that layout is not used.

```sh
zig build -Dlibrary-only=true -Dbackend=quickjs_ng -Doptimize=ReleaseFast --prefix zig-out/node-core
cmake -S sdk/node -B sdk/node/build -DCMAKE_BUILD_TYPE=Release -DJSBAY_LIBRARY="$PWD/zig-out/node-core/lib/libjsbay.a" -DNODE_INCLUDE="$NODE_INCLUDE"
cmake --build sdk/node/build --config Release
```

Install one engine-specific package for the backend you want:

- QuickJS: `npm install @jsbay/quickjs`
- QuickJS-NG: `npm install @jsbay/quickjsng`
- JavaScriptCore: `npm install @jsbay/jsc`

The `quickjs` and `quickjsng` packages provide prebuilt addons for Linux and macOS on x64 and arm64; `quickjsng` also provides Windows x64. The `jsc` package is available for macOS on x64 and arm64. npm selects the matching platform addon as an optional dependency. The Windows release workflow tests Electron 44.11.5 and confirms that the packaged application loads the addon from `app.asar.unpacked`. macOS addons target macOS 11.0 or newer, and package metadata records that deployment target. The release workflow checks every static library object and addon load command against that minimum. Runtime execution on macOS 11 has not been tested. Linux addons declare the GLIBC family and the package metadata records the minimum GLIBC symbol version required by the binary. CI installs and runs each engine package using the packed platform dependency and publishes the verified tarballs. Platform packages are published before the engine packages. Prerelease versions use the `next` npm dist-tag.

The repository source package exposes CommonJS through `require('./sdk/node')`; from an ES module, use `createRequire(import.meta.url)` and then require it. Set `JSBAY_NODE_ADDON` to load an explicit addon path during development.

## Use

```js
const { Engine } = require('@jsbay/quickjsng')
async function main() {
  const engine = Engine.create()
  engine.bindAsync('readValue', async () => ({ answer: 42 }))
  try {
    console.log(await engine.evaluateAsync('readValue().then(value => value.answer)'))
  } finally {
    engine.close()
  }
}
main().catch(console.error)
```

## API

| Call | Behavior |
| --- | --- |
| `Engine.create({ instanceId? })` | Creates an engine and attaches its owner loop; omitted IDs are allocated automatically |
| `Engine.create({ limits, onLog, onEvent })` | Sets all five resource caps and optionally forwards logs and telemetry events to the owner thread |
| `engine.evaluate(source, filename?)` | Returns a copied synchronous result; throws for a Promise result |
| `engine.evaluateAsync(source, filename?)` | Returns a Node.js Promise for a copied result or guest thenable settlement |
| `engine.evaluateValue(source, filename?, options?)` | Returns an owned `NodeValue` handle for a raw guest result, including functions and objects |
| `engine.value(hostValue)` / `engine.global()` / `engine.object()` / `engine.array()` | Creates an owned `NodeValue` from a host value or guest value |
| `engine.bind(name, callback)` | Installs a global synchronous native function |
| `engine.bindAsync(name, callback)` | Installs a global native function returning a guest Promise |
| `engine.close()` | Closes once, rejects pending evaluations, and ignores later host completions |
| `engine.closeAsync()` | Starts the same close and resolves after native teardown completes |
| `engine.postScript(source, filename?)` / `engine.postFence(options?)` | Submits work to the generation-scoped core FIFO and resolves at its VM checkpoint; a fence does not drain ordinary evaluation, Worker messages, or timers |
| `engine.requestInterrupt()` / `engine.cancel()` | Applies generation-scoped interruption or terminal cancellation from the engine's owner thread |
| `Engine.requestInterrupt(token)` / `Engine.cancel(token)` | Applies the same controls across Workers using the structured-cloneable `engine.controlToken` |
| `engine.beginShutdown(graceMs)` / `Engine.beginShutdown(token, graceMs)` | Starts the one-time generation-scoped graceful shutdown period |
| `engine.shutdownStatus()` / `Engine.shutdownStatus(token)` | Reads shutdown phase and remaining milliseconds; remaining time is a `bigint` |
| `engine.suspend()` / `engine.resume()` / `engine.runGc()` | Pauses or resumes loop work and runs a synchronous owner-thread GC pass |
| `engine.setExecutionTimeLimit(milliseconds)` | Sets the shared deadline for engine entries; zero disables it |
| `engine.setExecutionBudget(milliseconds)` | Sets a fresh deadline for each outer engine entry; zero disables it |
| `engine.setMemoryLimit(bytes)` | Sets the backend heap limit; zero removes the limit |
| `engine.inspectorStart(port)` / `engine.inspectorStop()` | Starts or stops the backend inspector; start returns its selected port |
| `engine.resourceUsage()` / `engine.memoryUsage()` | Returns snapshots with exact `bigint` counters |
| `engine.setLogHandler(callbackOrNull)` / `engine.setEventHandler(callbackOrNull)` | Replaces or clears one listener; queued notifications from a previous listener are discarded |
| `Engine.globalResourceUsage()` / `Engine.listEngines()` | Reads process-wide resource reservations or lists live instance IDs |
| `Engine.capabilities()` | Reports backend identity and supported optional features |

An explicit `instanceId` must be a positive int32 and unique across live engines in the process. Duplicate IDs fail without closing the existing engine. Resource limit options require all five non-negative integer fields: `maxTimers`, `maxTsfnHandles`, `maxPendingCalls`, `maxPendingBytes`, and `maxPendingTasks`. `Engine` is a factory object, not a constructor. `JsBayError` is a TypeScript interface, not an exported Error class; native status errors may carry a numeric `status`. A guest can throw or reject with a primitive value, so callers must not assume every failure is an Error. Optional backend features are reported by `Engine.capabilities()`; `sourceDebugger` reports debugger hooks, while `inspectorStart()` confirms that the build includes a listener transport and can bind the requested port. Other unsupported operations throw an error with status `JSBAY_UNSUPPORTED`.

Host callbacks execute on the same owner thread. `bindAsync` does not move CPU work to a worker: the callback starts there and can return a Promise or thenable for later completion. Host callback exceptions and unsupported argument conversions become guest exceptions that JavaScript can catch. `evaluateAsync` rejects for guest throws, rejected thenables, or result conversion failures.

## Values and lifetime

Ordinary host and guest values are copied directly between the runtimes, without JSON serialization. Supported values are undefined, null, booleans, numbers, strings, Error values, arrays, plain objects, ArrayBuffer, and array-buffer views. Binary views, including DataView and typed arrays, become copied ArrayBuffers. Own enumerable string properties and array holes are preserved; symbol keys and non-enumerable properties are not copied. Error message, name, and stack are copied. Object identity and shared references are not preserved. A single conversion accepts at most 10,000 nodes and 16 MiB of data copied into the target runtime; larger values are rejected. Public C ABI inputs can require a separate temporary source buffer, so this limit does not bound total transient allocation.

Functions, symbol values, bigint, custom accessors, unsupported prototypes, and structures deeper than 64 levels are rejected. Captured intrinsic Error stack getters are allowed and may invoke the runtime's stack-formatting hooks. Proxy reflection traps may execute; the SDK cannot identify Proxies through the portable C ABI.

Keep an engine on its creating thread; create a separate engine inside each Worker. The ordinary evaluation and binding methods exchange copied values. `NodeValue` is the explicit handle API for retaining guest values such as functions; call `retain()` for another owned handle and `close()` when done. Engine close invalidates all its `NodeValue` handles. Bindings retain their host callbacks until engine destruction. Call `close()` in `finally` to release them promptly; repeated close calls are harmless and later evaluations fail.

Closing rejects pending evaluations but does not abort the host's I/O or returned Promise. The host still owns cancellation of that work. Later completions cannot access a closed engine. Native cleanup waits for active callbacks to unwind. `closeAsync()` resolves after native teardown and pending callbacks have unwound; it does not wait for host I/O to finish. All engine methods, including `closeAsync()`, must run on the creating thread. Garbage-collector finalizers schedule cleanup on the owner loop, and environment shutdown releases native resources without calling JavaScript in the dying environment.

Pass `{ cacheDir, cacheVersion }` as the third argument to `evaluate`, `evaluateAsync`, or `evaluateValue` to enable the persistent bytecode cache. Both strings are required together. `lastCacheHit()` reports whether the most recent evaluation used a cached variant. Cache read or write failures fall back to evaluating the source once. `Engine.capabilities().bytecodeCache` indicates whether the selected build can persist cached bytecode; inspect the result before relying on cross-run cache hits. Runtime memory counters that a backend cannot report are zero. Log and event listeners may be set during creation or replaced/cleared later; close stops delivery, drops queued notifications, and suppresses exceptions thrown by listener functions.

## Validation

Run `bash tests/node-sdk/run_native_consumer.sh` to build and exercise the SDK. `JSBAY_LIBRARY` selects an existing compatible archive; otherwise the script builds QuickJS-NG. The helper requires CMake; set `CMAKE` to select its executable. Set `TSC` to a TypeScript compiler script to also check declarations and package import conditions. The independent consumer requires `--expose-gc`; the helper supplies it.

The helper builds a test addon with fault controls and a Release CMake addon. It runs the basic and independent consumers against both, runs the fault consumer against the test addon, and verifies that the production addon exports no test hooks. `JSBAY_NODE_RELEASE_ADDON` selects a prebuilt production addon, which lets CI exercise the exact binary it packages. See [SDK quality checks](../QUALITY.md) and the [testing guide](../../docs/testing.md#native-promise-and-nodejs-consumers) for coverage and CI entry points.

## Embedding

An existing Node-API addon can compile `src/jsbay_node.cpp` into its own module with `JSBAY_NODE_EMBEDDED` and include `include/jsbay_node_embed.h`. This keeps one addon, one linked JsBay core, and one owner event loop. Do not load the SDK as a second `.node` module for the same engine.

Native addons can group related typed Value calls with [`jsbay_engine_with_value_scope`](../../docs/api-contract.md#value-ownership). The Node.js SDK uses this entry when capturing and releasing its intrinsic references, avoiding repeated native-stack queries during those batches. The callback runs synchronously, preserves normal Value ownership, and catches C++ exceptions before returning. Its return from the scope ends the native lifetime lease, so asynchronous operations remain outside the batch.

Call `jsbay_node_create` with a positive instance id, optional native log handler, and a destruction callback. After creation succeeds, the destruction callback owns the supplied user data and runs once after the core engine has been destroyed. It can release native and Node-API references but must not call JavaScript or use JsBay values. `jsbay_node_set_task_observer` is for native metrics only; its callbacks must not call Node-API or JsBay APIs. `jsbay_node_close` requests the same deferred close used by `Engine.close` and is safe during a log callback or host callback.
