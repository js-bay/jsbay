# Host isolation and observability

## Do not own the UI thread

Create the engine on a dedicated owner thread (Android `HandlerThread` via
`Engine.createOnBackground`, Harmony Worker, Apple dedicated thread + `CFRunLoop`,
or a .NET thread with a `SynchronizationContext`). Synchronous `evaluate` and
value operations block the owner thread; putting that on the UI/main looper
causes ANRs / freezes.

`requestInterrupt` and `stopLoop` are the ordinary cross-thread controls. Every
other engine/Value API, including `getMemoryUsage`, `runGc`, destroy, and release,
must run on the owner thread.

## Soft failure ≠ crash isolation

Execution time limits, memory limits, `requestInterrupt`, and wrong-thread
checks are **cooperative soft failures**. They surface as `JsBayException` /
status codes while the process stays alive.

They do **not** isolate:

- native panics / segfaults inside the engine or JNI/N-API adapter
- process-wide OOM killer decisions
- deadlocks inside a host callback that never returns

A time limit and an engine thread share the host process address space. When the
host needs the app to survive an engine fault, run the engine in a **separate
process** (Android `android:process`, iOS/macOS XPC, Windows job+process) and
bridge with IPC. The public ABI remains a same-process thin layer.

The Android device harness `tests/android-sdk/run-crash-isolation-device.sh`
proves soft failures leave the process alive and documents the child-process
runner pattern for future isolate work. It does **not** claim same-process
native-fault containment.

## Process isolation proof (Zig abort does not kill host)

Same-process JNI/N-API + `libjsbay` still share the host address space: a real
native abort or segfault inside the engine kills that process.

Containment requires an **out-of-process** boundary. The Linux harness `tests/process-isolation/run.sh` proves it on the host; Android / Apple / Harmony device runners live under `tests/android-sdk/run-process-isolation-device.sh`, `tests/apple-sdk/run-process-isolation-sim.sh`, and `tests/harmony-sdk/run-process-isolation-device.sh`:

1. Default `-Dlibrary-only` ReleaseFast build exports **no**
   `jsbay_test_trigger_native_fault` (verified with `nm`).
2. A test-only build with `-Dfault-injection=true` exports that C ABI (abort /
   intentional SIGSEGV / panic). Publish scripts never pass this flag.
3. A parent process spawns a child that links the fault-injection library and
   triggers the probe; the child dies; the **parent stays alive** and can spawn
   a healthy evaluate child afterward.

Recommended production shape: engine in a separate process (`android:process`,
iOS/macOS XPC, Windows job+process) with a thin IPC bridge. The public product
ABI stays same-process; hosts that need survival must own the process boundary.


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



## Harmony multi-process Ability sketch

Same-process N-API + `libjsbay` still share the Ability process: a Zig abort
kills that process. Soft limits / `Engine.close` ordering do **not** contain it.

Containment on HarmonyOS:

1. Put the engine (or a fault probe) in a **second Ability** with
   `"process": ":jsbay_probe"` in `module.json5` (must match `^[:][0-9a-zA-Z_]+$`,
   ≤31 chars). That Ability runs in `bundleName:jsbay_probe`.
2. UI / host Ability starts it via `startAbility`, watches death with
   `appManager.on('applicationState')` / Ability lifecycle, then restarts.
3. Link `-Dfault-injection=true` **only** into a test rebuild of the probe
   process native library. Publish / `build-crash-isolation-hap.sh` product
   cores must keep `nm` free of `jsbay_test_trigger_native_fault`.

Device proof today:

- `tests/harmony-sdk/hap-crash-isolation/` ships `ProbeAbility` + CrashIsolation
  soft/close harness (`JSBAY_CRASHISO_PASS` on device).
- Shell-exec of a pushed ELF under `/data/local/tmp` remains **SELinux SKIP**.
- Real Zig-abort death of `:jsbay_probe` while UI survives still needs the
  fault-injection probe `.so` wired into ProbeAbility (not in product HAP).

