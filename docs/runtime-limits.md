# Runtime limits

`EngineConfig.resource_limits` bounds native timers, thread-safe function handles and calls, native tasks, dispatched scripts, and their queued payload bytes. The defaults and process-wide caps are defined by [`Limits`](../src/runtime/resource_limits.zig).

C callers that use `jsbay_engine_create` still get those defaults. Prefer `jsbay_engine_create_with_limits` when a host needs a tighter per-instance budget; pass a `jsbay_resource_limits_t` whose `struct_size` is `sizeof(jsbay_resource_limits_t)`. `jsbay_engine_set_resource_limits` replaces the Limits used for future admissions without destroying live reservations. `jsbay_engine_get_resource_usage` (owner thread) and `jsbay_resource_global_usage` (any thread) report current reservations plus the active Limits or process caps.

Zero is a strict limit, not a request to turn a limit off. A count limit of zero rejects every reservation of that resource. A byte limit of zero accepts only zero-byte work. Process-wide caps still apply, and admission is nonblocking within an admission class.

### Foreground headroom

Each process cap reserves a **foreground headroom** of 25% (rounded down; minimum 1 when the cap is nonzero). `jsbay_engine_set_admission_class` marks an instance `JSBAY_ADMISSION_FOREGROUND` (default) or `JSBAY_ADMISSION_BACKGROUND`. BACKGROUND admissions may use only `cap - headroom`; FOREGROUND may use the full cap. Changing class affects **future** `reserve` calls only — live reservations stay until release. Soft suspend/resume does **not** flip class; hosts should pair Hide → BACKGROUND (+ suspend) and Show → FOREGROUND (+ resume) when they want both keep-alive and quota preference. `jsbay_resource_global_usage` exposes headroom and effective BACKGROUND caps when `struct_size` includes those fields. There is still no fair-share scheduler and no stealing of live BACKGROUND work.

Rejected timer registration throws. Native-task and thread-safe-function admission reports failure. Script dispatch returns false when admission fails. Reservations are released after work runs, is cancelled, or the instance is destroyed.

`setExecutionTimeLimit` arms a relative deadline; zero disables it. `requestInterrupt` is cross-thread and nonblocking. Enforcement is cooperative, so a native callback that does not return can exceed a deadline. A time limit and an engine thread do not isolate memory or crashes; use a process boundary when that isolation is required.

QuickJS and QuickJS-NG apply the default 1 MiB JavaScript stack budget, capped to the current native thread's available stack where that can be measured. A configured zero does not disable this protection. JavaScriptCore exposes no equivalent public stack or heap-cap API. QuickJS-family heap limits cover the engine allocator, not process RSS, host allocations, threads, or Inspector state. See [backend selection](embedding.md#backend-selection) for backend support.

For owner-thread placement, soft-failure vs process isolation, and telemetry hooks, see [host-isolation.md](host-isolation.md).
