# Architecture

JS Bay presents one Zig and C-facing runtime API over QuickJS, QuickJS-NG, and JavaScriptCore. `src/backend.zig` selects one backend at compile time; it is not a runtime plug-in system. `src/root.zig` is the public Zig entry point, and `src/engine.zig` owns instance creation, evaluation, event-loop progress, and destruction.

## Package boundaries

The root package depends on `libs/zev`, `libs/js_event_loop`, `libs/inspector`, `libs/inspector_transport`, and `libs/bytecode_cache`. Each builds and tests independently. `inspector_transport` may depend on `inspector`, never the reverse; `bytecode_cache` has no JavaScript-engine dependency. Their generic APIs and standalone usage belong in their package READMEs. This document only records how the engine integrates them.

`libs/inspector` defines CDP state and the transport interface. `src/inspector/` supplies this engine's operations. `libs/inspector_transport` is an optional loopback HTTP/WebSocket transport and does not define Inspector semantics.

## Runtime model

An instance has one owner thread. Evaluation and value access run there. Cross-thread work uses dispatch and callback mechanisms and must not retain backend values across the boundary. Destruction closes new public work before active callbacks unwind.

The JavaScript event loop owns its native loop, monotonic clock, waiting, and wakeups. It runs on a dedicated owner thread or schedules opaque callbacks through a platform adapter. Each turn starts at most one queued JavaScript task and drains its microtasks. Timers, native tasks, and thread-safe function calls share that boundary.

`EngineConfig.module_loader` is the ES module-loader contract. QuickJS backends use resolve and load callbacks; supported Apple targets use a private Objective-C bridge. Source storage returned by `load` must remain valid after the callback returns. See [the API contract](api-contract.md) for opaque-value ownership and [runtime limits](runtime-limits.md) for resource controls.

## Source layout

`src/` keeps only these entry files at its root:

```text
root.zig  engine.zig  backend.zig  types.zig  c_api.zig  internal_tools.zig  test262_host.zig
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

The supported backend tags are `quickjs_ng`, `quickjs`, and `jsc`. A backend facade at `src/backend/<name>.zig` selects and exports the implementation below `src/backend/<name>/`. Shared QuickJS-family C support belongs in `src/backend/quickjs_common/`; it must not acquire a JSC dependency.

Do not add root-level forwarding files or move engine implementation into a standalone package merely to shorten imports. Directory placement follows ownership and dependency boundaries, not file size.
