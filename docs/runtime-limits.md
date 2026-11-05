# Runtime limits

`EngineConfig.resource_limits` bounds native timers, thread-safe function handles and calls, native tasks, dispatched scripts, and their queued payload bytes. The defaults and process-wide caps are defined by [`Limits`](../src/runtime/resource_limits.zig). C callers use the defaults.

Zero is a strict limit, not a request to turn a limit off. A count limit of zero rejects every reservation of that resource. A byte limit of zero accepts only zero-byte work. Process-wide caps still apply, and admission is nonblocking: one instance can consume capacity that another instance later needs.

Rejected timer registration throws. Native-task and thread-safe-function admission reports failure. Script dispatch returns false when admission fails. Reservations are released after work runs, is cancelled, or the instance is destroyed.

`setExecutionTimeLimit` arms a relative deadline; zero disables it. `requestInterrupt` is cross-thread and nonblocking. On QuickJS/NG (and JSC via time-limit callback) a true return means mid-script abort was armed. On experimental Escargot/Hermes spikes `requestInterrupt` **always returns false** and does not set the user bit — do not treat it as cancel (`supportsMidScriptUserInterrupt` is false). Escargot has no Public mid-script hook; Hermes mid-script abort is only via stop/destroy → `requestStopInterrupt` + `asyncTriggerTimeout` (sticky; softRearm/drain). Hermes create-time heap cap is Zig `EngineConfig.max_heap_size` / `-Dhermes-max-heap` / C `jsbay_engine_create_with_options.max_heap_size`, not `jsbay_engine_set_memory_limit` (always false on spike) and not plain `jsbay_engine_create`. Enforcement is cooperative, so a native callback that does not return can exceed a deadline. A time limit and an engine thread do not isolate memory or crashes; use a process boundary when that isolation is required.

QuickJS and QuickJS-NG apply the default 1 MiB JavaScript stack budget, capped to the current native thread's available stack where that can be measured. A configured zero does not disable this protection. JavaScriptCore exposes no equivalent public stack or heap-cap API. QuickJS-family heap limits cover the engine allocator, not process RSS, host allocations, threads, or Inspector state. See [backend selection](embedding.md#backend-selection) for backend support.

For owner-thread placement, soft-failure vs process isolation, and telemetry hooks, see [host-isolation.md](host-isolation.md).
