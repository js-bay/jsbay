# Embedding

## Backend selection

Single engine: `-Dbackend=quickjs`, `-Dbackend=jsc`, or `-Dbackend=quickjs_ng`. Product defaults are `jsc` for Apple packaging and classic `quickjs` everywhere else; `quickjs_ng` is optional.

Multi-engine pack: `-Dbackends=` with a comma-separated list (first entry is the pack primary). Do not pass `-Dbackend` and `-Dbackends` together. `quickjs` and `quickjs_ng` cannot share a pack (C symbol collision at link). Packing `jsc` needs an Apple target.

Lifecycle, eval, values, host objects, timers, references, finalizers, GC, and the C ABI are the same across backends. After link:

- `jsbay_library_backend` / `jsbay_library_capabilities` — primary backend and its capability bits
- `jsbay_available_backends` — every engine in the artifact
- `jsbay_engine_create_with_options` — pick a packed backend at create time (`JSBAY_BACKEND_PRIMARY` / 0 = primary). This is not a hot-switch of a live instance.

### Non-primary (packed-alt) Value surface

Non-primary instances use erased handles plus dispatch. Typed Value coverage that matches primary:

`evaluate` (owned handle), `retain` / `release`, `type`, `to_bool` / `to_number` / `to_utf8` / `to_json`, `get` / `set` / `has` / `delete` / `keys` / `instanceof`, `call` / `construct`, `new_*` (ArrayBuffer / JSON / Error), `global`, `copy_buffer`.

Packed handles set the high bit (`packed_api_value`) so they do not collide with primary `api_value` ids.

Still primary-only (non-primary returns `JSBAY_API_UNSUPPORTED` or refuses the option):

- `evaluate` with non-empty bytecode cache fields (empty / null `EvalOptions` is fine)
- bind
- inspector Value paths
- loop `attach` / `detach` / `run` on packed-alt

### Verify on Mac (NG+JSC)

```bash
zig build test -Dbackends=quickjs_ng,jsc -Dtest-filter="create_with_options"
zig build test -Dbackends=quickjs_ng,jsc -Dtest-filter="packed_alt"
zig build test -Dbackends=quickjs_ng,jsc -Dtest-filter="packed-alt"
zig build test -Dbackends=quickjs_ng,jsc -Dtest-filter="timer"
```

### Verify on Linux (single pack)

Linux cannot pack JSC (or both QuickJS variants). Use `-Dbackends=quickjs_ng` (or `quickjs`). Forced primary-tag `packed_alt` tests exercise the dispatch path without a second engine:

```bash
zig build test -Dbackends=quickjs_ng -Dtest-filter="packed"
zig build test -Dbackends=quickjs_ng -Dtest-filter="create_with_options"
zig build test -Dbackends=quickjs_ng -Dtest-filter="adversarial"
```

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

Import `jsbay`, choose a backend with `-Dbackend=quickjs`, `jsc`, or `quickjs_ng`, then use the typed `jsbay.c_api` namespace. The instance ID is supplied by the host and must be unique while the instance is alive.

```zig
const js = @import("jsbay");

const id = 1;
var limits = js.c_api.ResourceLimitsC{
    .struct_size = @sizeOf(js.c_api.ResourceLimitsC),
    .max_timers = 256,
    .max_tsfn_handles = 64,
    .max_pending_calls = 1024,
    .max_pending_bytes = 1 * 1024 * 1024,
    .max_pending_tasks = 1024,
};
if (!js.c_api.jsbay_engine_create_with_limits(id, null, null, &limits)) return error.EngineCreateFailed;
defer js.c_api.jsbay_engine_destroy(id);
```

`jsbay_engine_create` remains the default-budget entry point. Use `create_with_limits` when embedding several instances in one process so each app keeps a private timer/task budget under the shared process caps; see [runtime limits](runtime-limits.md).

The public Zig API mirrors the typed C ABI. Use `js.c_api.jsbay_engine_evaluate` and release every returned value with `js.c_api.jsbay_value_release`. The header and [api-contract.md](api-contract.md) define output ownership and exceptions.
The public Zig API mirrors the typed C ABI. Owner-thread observability includes `jsbay_engine_get_memory_usage`, `jsbay_engine_run_gc`, and `jsbay_engine_set_event_handler` (see [host-isolation.md](host-isolation.md)). Use `js.c_api.jsbay_engine_evaluate` and release every returned value with `js.c_api.jsbay_value_release`. The header and [api-contract.md](api-contract.md) define output ownership and exceptions.

## Thread and lifetime rules

Create, evaluate, run the loop, access values, and destroy on the owner thread. Do not store a value handle in work that may run on another thread. The ordinary cross-thread controls are `jsbay_engine_request_interrupt`, `jsbay_engine_stop_loop`, `jsbay_engine_suspend`, `jsbay_engine_resume`, and `jsbay_engine_destroy` (destroy joins teardown; prefer releasing values on the owner thread first); the synchronous-native extension has its own completion boundary.

`destroy` closes the instance to new public work. If it is called from JavaScript or a native callback, cleanup may wait until the callback unwinds. A destroyed value is never valid again, even if the same instance ID is reused.

The advanced `reference` helpers are available to Zig consumers that need retained backend values. Release or deinitialize those references on the owner thread.

### Multi-instance hosts (one owner thread per instance id)

Hosts that keep several engines alive at once (for example multiple guest runtimes in one process) must give **each `instance_id` its own dedicated owner thread**, not the process main/UI thread.

| Platform | Default guard | Recommended pattern |
| --- | --- | --- |
| Android | `Engine(id)` refuses automatic LoopDriver attach when the current Looper is the main Looper (`INVALID_ARGUMENT`). Opt in with `EngineOptions(allowMainLooperAttach = true)`. | `DedicatedEngineThread.start(instanceId)` — one Handler/Looper thread per instance |
| Apple | `Engine(id:)` / `initWithIdentifier:error:` refuse attach when the current CFRunLoop is the main run loop. Opt in with `allowMainRunLoopAttach`. `runLoop()` also refuses the main thread without that opt-in. | Dedicated thread + `CFRunLoopRun`, construct the engine there |
| Harmony | Native bridge pins `std::this_thread::get_id()` at create and returns `WrongThread` off-owner. | One ArkTS Worker per instance id; never transfer Engine/Value wrappers |

Sharing the main/UI thread across many engines causes jank and can deadlock with synchronous bridge calls. SDK READMEs under `sdk/android`, `sdk/apple`, and `sdk/harmony` spell out the platform APIs.

`DedicatedEngineThread.close()` destroys the engine on the owner Looper. If that Looper is already dead and `Handler.post` fails, close throws `INSTANCE_NOT_FOUND` and **keeps** the Kotlin `engineRef` so the native `instance_id` is not silently leaked from the SDK's point of view. There is no safe cross-thread `destroy` fallback; recover by process restart or ensuring the owner thread is alive before close.

## Event-loop progress

The JavaScript event loop owns its monotonic clock, timers, waiting, and wakeups. Call `jsbay_engine_run_loop` on a dedicated owner thread, or let the SDK connect it to the platform owner thread. `jsbay_engine_stop_loop` is thread-safe. When no run is active it applies to the next `jsbay_engine_run_loop`, which consumes it, and attaching a platform loop discards a request made before it. While a platform loop is attached it stops that loop's driving until detach and a later attach. Each queued JavaScript task finishes with a microtask checkpoint; callers do not supply timestamps or compute deadlines.

For multi-runtime Hide/Show keep-alive, use `jsbay_engine_suspend` / `jsbay_engine_resume` (also thread-safe). Suspend pauses JS turns and cancels a pending platform schedule without detaching the Host or clearing timers, tasks, binds, or globals. Resume re-schedules attached work so overdue timers catch up on real monotonic time; it never destroys or recreates the engine. Map container Hide → suspend and Show → resume. Do not use `stop_loop`, `detach_loop`, or `destroy` as a stand-in for Hide: stop ends a blocking `run_loop`, detach drops the platform binding, and destroy tears down the VM.

Hosts should still sequence owner-thread `destroy` after the last intended Hide/Show for that instance.

### Multi-instance observability

`jsbay_engine_list` (any thread) returns the count of live, non-teardown-pending instances and optionally copies those ids. `jsbay_engine_snapshot` (any thread) fills a `jsbay_instance_snapshot_t` with generation, owner thread id, loop mode, suspend/attach/failed/sync-wait flags, admission class, queue depths, and usage/Limits. Snapshots may tear across locks; they are for ops dashboards, not for atomic decisioning. Both refuse teardown-pending instances (snapshot returns false; list omits them). Flag bit2 is reserved/unused.

The engine refuses new suspend/resume/stop once teardown is pending and waits for in-flight control-plane calls before freeing the Driver, but racing destroy against a late Show remains host-level undefined behavior for application logic (the late call returns false / instance-not-found).

Do not run a second scheduler for the same instance. Do not attach multiple engines to the process main Looper / main CFRunLoop / UI Worker.

## C and SDKs

The stable C declarations are in `include/jsbay.h`. Android, Apple, .NET, and Harmony are wrappers over that ABI; their READMEs provide installation and linker settings. Create an engine on its owner thread, use it there, and release every owned `jsbay_value_t` there before teardown. Prefer `jsbay_engine_destroy` on the owner after that release; it may also be called from another thread and will join teardown (see Host shutdown checklist). Do not let a finalizer or garbage collector call destroy or value-release APIs. SDKs expose the same Limits fields as optional create arguments plus usage queries; defaults match `jsbay_engine_create`.

All C text input is length-delimited UTF-8. `data == NULL && len == 0` is an empty string; a null pointer with a nonzero length is invalid. Returned `jsbay_bytes_t` storage belongs to the library and must be released with `jsbay_free_bytes` exactly once (double free aborts). Check every `jsbay_status_t`; a JavaScript exception is an owned value, not necessarily a string.

## Debugging embed (pauseable Debugger)

When DevTools must block on `Debugger.pause` or `debugger;`, keep the engine off the host UI thread and off the Node.js main thread. The runnable C sample is [`examples/debug_owner_embed.c`](../examples/debug_owner_embed.c):

1. A dedicated **owner** thread calls `jsbay_engine_create`, `jsbay_engine_inspector_start`, then `jsbay_engine_run_loop`.
2. After `run_loop` returns, that same thread calls `jsbay_engine_inspector_stop` and `jsbay_engine_destroy`.
3. The **main / host client** thread only prints the bound port and calls `jsbay_engine_stop_loop` (thread-safe). It does not own the engine.

Build and run (prefer `quickjs_ng` when Sources / breakpoints matter; plain `quickjs` advertises no Debugger domain):

```sh
zig build -Dbackend=quickjs_ng                    # installs zig-out/bin/debug-owner-embed-quickjs_ng
zig build debug-owner-embed -Dbackend=quickjs_ng -- --port 9229
# automated smoke (ephemeral port, no DevTools required):
zig build debug-owner-embed-test -Dbackend=quickjs_ng
# or compile tests/debug_owner_embed_consumer.c against zig-out/lib/libjsbay.a
```

`jsbay_engine_attach_loop` on a Node.js (or similar) main thread combined with blocking Debugger pause deadlocks: pause holds the owner while the host loop that would deliver resume CDP cannot run. Non-pausing Runtime / console inspection can still use an attached platform loop when the host accepts that Debugger pause is unavailable. See also [Inspector](inspector.md).

## Host shutdown checklist

Tear the instance down in this order on a live host:

1. Stop posting new work to the instance.
2. If `jsbay_engine_run_loop` is active, call `jsbay_engine_stop_loop` (any thread) and wait until the owner's `run_loop` returns. If a platform loop was attached, call `jsbay_engine_detach_loop` on the owner (after that loop has stopped driving, as documented under Event-loop progress).
3. Call `jsbay_engine_inspector_stop` on the owner thread if Inspector was started.
4. Release every caller-owned `jsbay_value_t` (and any SDK retain / reference) on the owner thread.
5. Call `jsbay_engine_destroy` on the owner thread (preferred). It is also thread-safe and joins teardown when called from a foreign control thread — use that for destroy-then-`Worker.terminate` so the owner is not killed mid-`run_loop`.
6. Only then `Worker.terminate`, unload the N-API addon, or tear down the host isolate that owned the bridge.

Destroy is idempotent and closes the instance to new public work immediately, but physical teardown may wait until an in-flight JavaScript or native callback returns. Do not call destroy or value-release APIs from a garbage-collector finalizer. The same rules are stated in [api-contract.md](api-contract.md).

## Version pinning

Call `jsbay_engine_version` to read the process-wide build identity (`version` from `build.zig.zon`, optional `commit`, and the compile-time `-Dbackend` tag). The returned C strings are library-owned and remain valid for the lifetime of the loaded library.

Pin consumers to a release `v*` tag, or to an exact git commit plus `-Dbackend=...`. When building or packaging the engine, pass `-Dgit-commit=<sha>` so the recorded commit matches the release archive `COMMIT` file (local checkouts auto-detect `HEAD` when that option is omitted). Desktop release archives also ship `VERSION`, `COMMIT`, and `backend` text files; see [release.md](release.md).

## Modules and native functions

The stable C ABI has no general module-loader registration. Use its normal evaluation entry point and configure any application-specific loading outside the runtime. Native callbacks receive borrowed value handles. Copy ordinary data before starting asynchronous work; retain a value only through the supported reference or retain APIs. For the optional synchronous-native bridge, read [native-sync.md](native-sync.md).

The C and SDK contract, including ownership and status semantics, is in [api-contract.md](api-contract.md).
