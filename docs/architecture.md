# Architecture

JS Bay presents one Zig and C-facing runtime API over QuickJS, QuickJS-NG, and JavaScriptCore. Build options select statically linked backends and a primary backend in `src/backend.zig`; multi-engine packs select a packed backend at instance creation, not by loading runtime plug-ins. `src/root.zig` is the public Zig entry point, and `src/engine.zig` owns instance creation, evaluation, event-loop progress, and destruction.

## Package boundaries

The root package depends on `libs/zev`, `libs/js_event_loop`, `libs/inspector`, `libs/inspector_transport`, `libs/bytecode_cache`, and `libs/commonjs`. Each builds and tests independently. `inspector_transport` may depend on `inspector`, never the reverse; `bytecode_cache` and `commonjs` have no JavaScript-engine dependency. Their generic APIs and standalone usage belong in their package READMEs. This document only records how the engine integrates them.

`libs/inspector` defines CDP state and the transport interface. `src/inspector/` supplies this engine's operations. `libs/inspector_transport` is an optional loopback HTTP/WebSocket transport and does not define Inspector semantics.

`libs/commonjs` owns canonical IDs, loading transactions, cyclic partial exports, instance caching and cache-reference release through narrow loader/execution/reference operations. `src/script/cjs/` owns actual VM wrapper execution, per-module require closures, native registration, bytecode policy, admission and teardown timing. It does not pass an engine-wide Host/backend/instance map into the package. See [the standalone contract](../libs/commonjs/readme.md). The package is repository-local, not an external registry release.

## Runtime model

An instance has one owner thread. Evaluation and value access run there. Cross-thread work uses dispatch and callback mechanisms and must not retain backend values across the boundary. Destruction closes new public work before active callbacks unwind.

The JavaScript event loop owns its native loop, monotonic clock, waiting, and wakeups. It runs on a dedicated owner thread or schedules opaque callbacks through a platform adapter. Each turn starts at most one queued JavaScript task and drains its microtasks. Timers, native tasks, and thread-safe function calls share that boundary.

`EngineConfig.module_loader` is the ES module-loader contract. QuickJS backends use resolve and load callbacks; supported Apple targets use a private Objective-C bridge. Source storage returned by `load` must remain valid after the callback returns. See [the API contract](api-contract.md) for opaque-value ownership and [runtime limits](runtime-limits.md) for resource controls.

## Source layout

Root-level `src/` files are public facades or build/test entry points, including:

```text
root.zig  engine.zig  backend.zig  backend_dispatch.zig  types.zig  c_api.zig
internal_tools.zig  multi_pack.zig  test262_host.zig  cjs_component_tests.zig
```

All new implementation files belong to one of these directories.

| Directory | Responsibility |
| --- | --- |
| `backend/` | A backend facade and engine-specific implementation. |
| `abi/` | C-compatible values, callbacks, and opaque handles. |
| `platform/` | Platform compatibility, low-level I/O, synchronization, and stack probing. |
| `runtime/` | Instance state, owner-thread checks, dispatch, scheduling, timers, async work, and limits. |
| `inspector/` | Engine-side CDP integration. Protocol state and network transport stay in `libs/`. |
| `value/` | Values, references, host objects, buffers, symbols, and native-handle lifetime. |
| `script/` | Evaluation, modules, bytecode, and persistent-cache integration. |
| `tests/` | Root-package Zig tests. Consumer and platform tests are in the repository-level `tests/`. |

The supported backend tags are `quickjs_ng`, `quickjs`, and `jsc`. A backend facade at `src/backend/<name>.zig` selects and exports the implementation below `src/backend/<name>/`. Shared QuickJS-family C and Zig support belongs in `src/backend/quickjs_common/`; it must not acquire a JSC dependency.

Do not add root-level forwarding files or move engine implementation into a standalone package merely to shorten imports. Directory placement follows ownership and dependency boundaries, not file size.

## QuickJS-family sharing

The QuickJS and QuickJS-NG facades specialize shared algorithms with their own native API namespace. Buffers, collections, dates, bytecode, CommonJS evaluation, ES module loading, external values, host function marshalling, job hooks, symbols, timers, weak finalizer callbacks, DataView windows, typed error construction and host-object own-key ordering share implementation without sharing native declarations. DataView and Error predicates stay in the facades because their native signatures differ. Diagnostic console serialization is shared in `src/inspector/backends/quickjs_console.zig`; normal console formatting remains backend policy.

Each facade creates one specialization. External class IDs and mutexes, host binding slots, runtime cleanup maps, weak callback counters and error-construction thread-local depth are declared inside the specialization, not in the shared file namespace. Callback and payload types stay tied to the supplied C API. Instance lookup, host-value types, native handles, async stacks, timer scheduling, exception formatting and execution admission are explicit collaborators where used; no shared helper selects an active backend or receives an engine-wide Host.

Native declarations, lifecycle/admission, value dispatch, rejection coordination, host-object exotic methods, weak references and runtime-limit adapters remain backend-owned. They contain native ABI or policy differences: process-wide versus per-runtime class IDs; native versus installed microtasks; array, equality and constructor predicates; rejection callback boolean representation and uncatchable errors; property-descriptor field types; strict-equality entry points; and unlimited-memory sentinel normalization. These are not cross-engine implementations. Bytecode fingerprints include both the backend adapter and shared bytecode implementation.
