# Host isolation and observability

## Do not own the UI thread

Create the engine on a dedicated owner thread (Android `HandlerThread` via
`Engine.createOnBackground`, Harmony Worker, Apple dedicated thread + `CFRunLoop`,
or a .NET thread with a `SynchronizationContext`). Synchronous `evaluate` and
value operations block the owner thread; putting that on the UI/main looper
causes ANRs / freezes.

`requestInterrupt`, `stopLoop`, and generation-scoped shutdown controls may be called from a control thread. The C ABI also accepts cross-thread script and fence submissions; the language SDK wrappers bind submissions to the engine owner thread. Synchronous evaluation, Value operations (including release), `getMemoryUsage`, and `runGc` remain owner-thread operations. The C ABI `jsbay_engine_destroy` is thread-safe and joins teardown when called off-owner; SDK close/dispose follows each wrapper's owner-thread contract. See [api-contract.md](api-contract.md) for accepted-submission and cancellation semantics.

## Soft failure ≠ crash isolation

Execution time limits, memory limits, `requestInterrupt`, and wrong-thread
checks are **cooperative soft failures**. They surface as `JsBayException` /
status codes while the process stays alive.

They do **not** isolate:

- native panics / segfaults inside the engine or JNI/N-API adapter
- process-wide OOM killer decisions
- deadlocks inside a host callback that never returns

A time limit and an engine thread share the host process address space. When the host needs the app to survive an engine fault, it needs a supported separate-process boundary and IPC. The public ABI remains a same-process thin layer.

Android supports a component `android:process` boundary. A production host must use a dedicated Service, bind over Binder, fail every in-flight request when the Service dies, and construct a fresh engine session before accepting new work.

iOS applications cannot spawn a general child process. macOS XPC services do not establish an iOS product design. An iOS host therefore has no generic native-engine crash-isolation implementation in this SDK; `WKWebView` is a different backend with its own process model, not a recovery wrapper for this engine.

Harmony child-process APIs require a device that supports them. Hosts must feature-detect the start result and retain same-process failure semantics when the platform returns `801` (not supported) or `16010004` (multi-process disabled).

The Android device harness `tests/android-sdk/run-crash-isolation-device.sh`
proves soft failures leave the process alive and documents the child-process
runner pattern for future isolate work. It does **not** claim same-process
native-fault containment.

## Process isolation proof (Zig abort does not kill host)

Same-process JNI/N-API + `libjsbay` still share the host address space: a real
native abort or segfault inside the engine kills that process.

Containment requires an **out-of-process** boundary. The Linux harness `tests/process-isolation/run.sh` proves only a POSIX parent/child boundary on the host. Android / Apple / Harmony runners under `tests/android-sdk/run-process-isolation-device.sh`, `tests/apple-sdk/run-process-isolation-sim.sh`, and `tests/harmony-sdk/run-process-isolation-device.sh` are platform experiments; they do not by themselves prove a publishable mobile-app boundary:

1. Default `-Dlibrary-only` ReleaseFast build exports **no**
   `jsbay_test_trigger_native_fault` (verified with `nm`).
2. A test-only build with `-Dfault-injection=true` exports that C ABI (abort /
   intentional SIGSEGV / panic). Publish scripts never pass this flag.
3. A parent process spawns a child that links the fault-injection library and triggers the probe; the child dies with the expected signal; the **parent stays alive** and can spawn a healthy evaluate child afterward.

Recommended production shape: Android may use `android:process` with a thin IPC bridge. macOS may use XPC. iOS and unsupported Harmony devices have no equivalent product boundary here. The public product ABI stays same-process; hosts that need survival must own and test the process boundary.


## Observability APIs for reporting

| Surface | Purpose |
| --- | --- |
| `jsbay_log_handler_t` on create | Console / engine log lines |
| `jsbay_engine_set_event_handler` | Telemetry: log, interrupt, memory limit, loop failed |
| `jsbay_engine_get_memory_usage` | Allocator snapshot (owner thread) |
| `jsbay_engine_run_gc` | Forced GC (owner thread) |

Event handlers must not call engine/Value APIs. They may run on the owner thread
or, for `request_interrupt`, on the control-plane thread.

See also [runtime-limits.md](runtime-limits.md) and [api-contract.md](api-contract.md).

## Harmony Worker close ordering

Ordered teardown on the **owner Worker** (the N-API thread that called `Engine.create`):

1. Cancel / stop the JS event loop (`stopLoop` or let pending host timers settle).
2. Close owned `Value` wrappers (bindings, retained handles).
3. Call `engine.close()` — Harmony `closeEngine` is **synchronous** (`jsbay_engine_destroy` on the owner thread) and detaches the napi env cleanup hook.
4. **Only then** `ThreadWorker.terminate()`.

Never `postMessage(destroy/close)` and immediately `terminate()` without waiting for native destroy to finish. That host anti-pattern (post destroy then immediately `terminate` while an async engine teardown is still running) races native cleanup against Worker death → orphan engine / TSFN into a dead env / UAF. JsBay uses synchronous `closeEngine` on the owner thread (no detached engine pthread behind the Worker), but abrupt `terminate()` without `engine.close()` still relies on `napi` `envCleanup` as a safety net and is not the recommended host path.

If the Worker environment is torn down without an explicit `close()`, the registered env cleanup hook destroys the instance on the env owner thread before TSFN user data is invalidated. Late `runLoopTask` / TSFN wakes with a stale generation must no-op or soft-fail — they must not use freed loop user_data.

Harnesses:

- Node (same C++ bridge): `tests/harmony-sdk/crash_isolation_consumer.cjs` via `run-crash-isolation-harmony.sh --node-only`
- Device ArkTS: `CrashIsolation.ets` + `CrashIsolationWorker.ets` (via `HDC` / `HDC_SERIAL`)

Soft limits and wrong-thread checks still do **not** contain native faults in-process.



## Harmony child-process capability

Same-process N-API + `libjsbay` still share the Ability process: a Zig abort
kills that process. Soft limits / `Engine.close` ordering do **not** contain it.

The SDK exposes ArkTS and native child-process APIs from API level 12. Availability depends on the device and system capabilities. Hosts must handle unsupported startup results and establish the child-process boundary before relying on native-fault isolation.

On a device where the API is supported, a host must:

1. Start a child through the platform child-process API and use its documented IPC mechanism.
2. Give each request a generation and deadline; fail outstanding requests when the child dies or IPC disconnects; construct a new engine generation before retrying.
3. Link `-Dfault-injection=true` only into a test rebuild of the child native library. Publish product cores must keep `nm` free of `jsbay_test_trigger_native_fault`.

Harness coverage:

- `tests/harmony-sdk/hap-crash-isolation/` exercises same-process execution limits and close ordering. Its success marker does not establish a child-process boundary.
- Executing a standalone native binary through a shell does not establish the application's child-process and IPC capabilities; platform security policy may reject it.
- Real child fault, parent survival, IPC failure, and fresh-generation recovery require a supported device and a fault-injection child test build.

