# Embedding

## Backend selection

Build with `-Dbackend=quickjs_ng`, `-Dbackend=quickjs`, or `-Dbackend=jsc`. All backends support engine lifecycle, ordinary evaluation, values, host objects, timers, references, finalizers, explicit GC, and the common C ABI.

| Capability | JSC | QuickJS | QuickJS-NG |
| --- | --- | --- | --- |
| Configurable JavaScript stack and heap limit | No public heap or stack limit | Yes | Yes |
| Heap usage snapshot | No supported engine snapshot | Yes | Yes |
| Interrupt and execution deadline | Platform-dependent integration | Yes | Yes |
| ES modules with `ModuleLoader` | Private bridge on supported Apple platforms | Resolve and load callbacks | Resolve and load callbacks |
| CommonJS bytecode and persistent bytecode cache | Source fallback only | Yes | Yes |
| CDP source debugging | No | No | Partial support |
| CDP Runtime and Performance | Partial | Partial | Partial |
| Safari Web Inspector | JSC only | No | No |

`setMemoryLimit(id, 0)` means unlimited through the common API. QuickJS needs an adapter because its native zero means a zero-byte limit; QuickJS-NG already treats zero as unlimited. Engine limits are not process-memory limits. [Runtime limits](runtime-limits.md) explains the admission and isolation boundaries; [Inspector](inspector.md) describes its optional build switches and protocol limits.

## Zig

Import `jsbay`, choose a backend with `-Dbackend=quickjs_ng`, `quickjs`, or `jsc`, then use the typed `jsbay.c_api` namespace. The instance ID is supplied by the host and must be unique while the instance is alive.

```zig
const js = @import("jsbay");

const id = 1;
if (!js.c_api.jsbay_engine_create(id, null, null)) return error.EngineCreateFailed;
defer js.c_api.jsbay_engine_destroy(id);
```

The public Zig API mirrors the typed C ABI. Owner-thread observability includes `jsbay_engine_get_memory_usage`, `jsbay_engine_run_gc`, and `jsbay_engine_set_event_handler` (see [host-isolation.md](host-isolation.md)). Use `js.c_api.jsbay_engine_evaluate` and release every returned value with `js.c_api.jsbay_value_release`. The header and [api-contract.md](api-contract.md) define output ownership and exceptions.

## Thread and lifetime rules

Create, evaluate, run the loop, access values, and destroy on the owner thread. Do not store a value handle in work that may run on another thread. The ordinary cross-thread controls are `jsbay_engine_request_interrupt` and `jsbay_engine_stop_loop`; the synchronous-native extension has its own completion boundary.

`destroy` closes the instance to new public work. If it is called from JavaScript or a native callback, cleanup may wait until the callback unwinds. A destroyed value is never valid again, even if the same instance ID is reused.

The advanced `reference` helpers are available to Zig consumers that need retained backend values. Release or deinitialize those references on the owner thread.

## Event-loop progress

The JavaScript event loop owns its monotonic clock, timers, waiting, and wakeups. Call `jsbay_engine_run_loop` on a dedicated owner thread, or let the SDK connect it to the platform owner thread. `jsbay_engine_stop_loop` is thread-safe. Each queued JavaScript task finishes with a microtask checkpoint; callers do not supply timestamps or compute deadlines.

Do not run a second scheduler for the same instance.

## C and SDKs

The stable C declarations are in `include/jsbay.h`. Android, Apple, .NET, and Harmony are wrappers over that ABI; their READMEs provide installation and linker settings. Create an engine on its owner thread, use it there, release every owned `jsbay_value_t`, then destroy it there. Do not let a finalizer or garbage collector call destroy or value-release APIs.

All C text input is length-delimited UTF-8. `data == NULL && len == 0` is an empty string; a null pointer with a nonzero length is invalid. Returned `jsbay_bytes_t` storage belongs to the library and must be released with `jsbay_free_bytes` exactly once (double free aborts). Check every `jsbay_status_t`; a JavaScript exception is an owned value, not necessarily a string.

## Modules and native functions

The stable C ABI has no general module-loader registration. Use its normal evaluation entry point and configure any application-specific loading outside the runtime. Native callbacks receive borrowed value handles. Copy ordinary data before starting asynchronous work; retain a value only through the supported reference or retain APIs. For the optional synchronous-native bridge, read [native-sync.md](native-sync.md).

The C and SDK contract, including ownership and status semantics, is in [api-contract.md](api-contract.md).

## Experimental Escargot / Hermes (spike)

These backends are **not** production-default. Hard rules:

- **Escargot engine_thread × host**: Context is **thread-affine**. `hostInstall` is refused while the engine thread is running; `threadStart` is refused if hosts are already installed. Crossing that boundary historically SEGV'd (AtomicString/GC) — the refuse path is intentional, not a temporary Skip.
- **`jsbay_engine_request_interrupt`**: returns **false** on Escargot/Hermes (no mid-script user interrupt). Hermes stop/destroy still cancels via lifecycle interrupt.
- **`jsbay_engine_set_memory_limit`**: always **false** on spike. Hermes create-time heap: `jsbay_engine_create_with_options` / Zig `EngineConfig.max_heap_size` / `-Dhermes-max-heap`.
- Rebuild prefixes: `scripts/rebuild-icu-prefix.sh`, `scripts/rebuild-hermes-install.sh`, `scripts/rebuild-escargot-install.sh`. See [capability.md](capability.md).
