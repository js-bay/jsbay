# JS Bay Node.js SDK

The Node.js SDK loads JsBay through Node-API. `Engine` is thread-affine: create, evaluate, bind, and close it on the same JavaScript thread. Each engine attaches to the Node.js event loop. Explicitly close engines when their work is complete; garbage collection and environment cleanup provide fallback disposal.

`bind` exposes a synchronous host callback. `bindAsync` returns a guest Promise and accepts a host value, Promise, or thenable. Native Promise creation and settlement use the [public asynchronous C ABI](../../docs/native-async.md). `evaluate` copies a synchronous result and rejects Promise results; `evaluateAsync` returns a Node.js Promise and waits for guest thenables. The SDK does not inject JavaScript source or a request table into the guest.

## Build

Build a compatible archive from the repository root, then build the addon with CMake. `NODE_INCLUDE` must contain `node_api.h` and `uv.h` for the target Node.js or Electron installation. The supported build scripts target macOS and Linux; Windows packaging is not provided.

Requirements are the repository's Zig toolchain, CMake, a C++17 compiler, and matching Node.js or Electron development headers. Set `NODE_INCLUDE` to the directory containing those headers. If Node.js headers are installed alongside its executable, `NODE_INCLUDE="$(node -p 'require("node:path").resolve(process.execPath, "../../include/node")')"` locates that directory; verify that both header files exist before building. An explicit header directory is needed when that layout is not used.

```sh
zig build -Dlibrary-only=true -Dbackend=quickjs_ng -Doptimize=ReleaseFast --prefix zig-out/node-core
cmake -S sdk/node -B sdk/node/build -DCMAKE_BUILD_TYPE=Release -DJSBAY_LIBRARY="$PWD/zig-out/node-core/lib/libjsbay.a" -DNODE_INCLUDE="$NODE_INCLUDE"
cmake --build sdk/node/build --config Release
```

Load the source package with `require('./sdk/node')`, or its package name after installing it locally. The package exposes CommonJS; from an ES module, use `createRequire(import.meta.url)` and then require the package. Set `JSBAY_NODE_ADDON` to load an explicit addon path during development or packaging. No prebuilt binaries or npm release are included.

## Use

```js
const { Engine } = require('./sdk/node')
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
| `engine.evaluate(source, filename?)` | Returns a copied synchronous result; throws for a Promise result |
| `engine.evaluateAsync(source, filename?)` | Returns a Node.js Promise for a copied result or guest thenable settlement |
| `engine.bind(name, callback)` | Installs a global synchronous native function |
| `engine.bindAsync(name, callback)` | Installs a global native function returning a guest Promise |
| `engine.close()` | Closes once, rejects pending evaluations, and ignores later host completions |

An explicit `instanceId` must be a positive int32 and unique across live engines in the process. Duplicate IDs fail without closing the existing engine. `Engine` is a factory object, not a constructor. `JsBayError` is a TypeScript interface, not an exported Error class; native status errors may carry a numeric `status`. A guest can throw or reject with a primitive value, so callers must not assume every failure is an Error.

Host callbacks execute on the same owner thread. `bindAsync` does not move CPU work to a worker: the callback starts there and can return a Promise or thenable for later completion. Host callback exceptions and unsupported argument conversions become guest exceptions that JavaScript can catch. `evaluateAsync` rejects for guest throws, rejected thenables, or result conversion failures.

## Values and lifetime

Values are copied directly between the runtimes, without JSON serialization. Supported values are undefined, null, booleans, numbers, strings, Error values, arrays, plain objects, ArrayBuffer, and array-buffer views. Binary views, including DataView and typed arrays, become copied ArrayBuffers. Own enumerable string properties and array holes are preserved; symbol keys and non-enumerable properties are not copied. Error message, name, and stack are copied. Object identity and shared references are not preserved. A single conversion accepts at most 10,000 nodes and 16 MiB of data copied into the target runtime; larger values are rejected. Public C ABI inputs can require a separate temporary source buffer, so this limit does not bound total transient allocation.

Functions, symbol values, bigint, custom accessors, unsupported prototypes, and structures deeper than 64 levels are rejected. Captured intrinsic Error stack getters are allowed and may invoke the runtime's stack-formatting hooks. Proxy reflection traps may execute; the SDK cannot identify Proxies through the portable C ABI.

Keep an engine on its creating thread; create a separate engine inside each Worker. Node.js callers receive ordinary copied values rather than C handles, so they do not manually retain or release them. Bindings retain their host callbacks until engine destruction. Call `close()` in `finally` to release them promptly; repeated close calls are harmless and later evaluations fail.

Closing rejects pending evaluations but does not abort the host's I/O or returned Promise. The host still owns cancellation of that work. A pending `evaluateAsync` keeps its engine alive until it settles or `close()` is called. Later completions cannot access a closed engine. Native cleanup waits for active callbacks to unwind; garbage-collector finalizers schedule cleanup on the owner loop, and environment shutdown releases native resources without calling JavaScript in the dying environment.

## Validation

Run `bash tests/node-sdk/run_native_consumer.sh` to build and exercise the SDK. `JSBAY_LIBRARY` selects an existing compatible archive; otherwise the script builds QuickJS-NG. The helper requires CMake; set `CMAKE` to select its executable. Set `TSC` to a TypeScript compiler script to also check declarations and package import conditions. The independent consumer requires `--expose-gc`; the helper supplies it.

The helper builds both a test addon with fault controls and a Release CMake addon. It runs the basic and independent consumers against both, runs the fault consumer only against the test addon, and verifies that the production addon exports no test hooks. See [SDK quality checks](../QUALITY.md) and the [testing guide](../../docs/testing.md#native-promise-and-nodejs-consumers) for coverage and CI entry points.
