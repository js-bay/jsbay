# js_event_loop

JavaScript scheduling on `zev`. Depends on `zev` and the Zig stdlib; no JS engine or host API bindings here.

## Driver ↔ zev

`Driver` owns the native `zev.Loop` (clock, wait, timers, notifiers, turns).

- dispatch: `dispatchEventsLimited`; optional `dispatch_budget` / `dispatch_time_budget_ms` (`null` = unlimited)
- `Driver.now` → `Loop.nowMs`
- tests: `Driver.testing.advance` / `setNow` install `Loop.setClock` (no parallel `test_now`)
- notify / timer start use zev coalesce; attached hosts get a schedule nudge. `cancel` and public `wake` still signal the waiter
- blocking `run` / `runFor` wrap `beginRun` / `endRun` so owner wake-skip matches `Loop.run`
- virtual clock: park for an external wake; do not sleep a virtual delay as wall time

`run` / `runFor` drive on a dedicated thread. `attach` drives on a platform-owned thread. Callers do not pump turns, sample clocks, or compute deadlines.

## Attach / suspend

Platform supplies coalescing async `Host.schedule` and owner-thread `Host.cancel`, then invokes the drive callback (`runAttached` under the engine lease). Driver schedules its next callback after each turn, wakes early on timer/notify, idle otherwise. `detach` on the owner thread before releasing the runtime; it waits for in-flight Host schedule/cancel so the Host may free `context` only after that cancel returns. Blocking `run` and attached driving are mutually exclusive.

`suspendScheduling` / `resumeScheduling` pause turns and Host schedules without detaching or clearing timers/tasks (Hide/Show). Soft `Host.cancel` must stay reusable; hard teardown belongs to detach/destroy.

`requestStop` ends the active blocking run; when none is active it applies to the next run and is consumed by the run that ends. `attach` discards a prior idle stop. While attached it freezes platform driving until `detach` + later `attach`.

## Handles

`Timer` / `Notifier` are Driver wrappers. Init with a Driver; schedule absolute or relative times; notify from another thread. Do not touch `zev.Loop` directly.

## Scheduler

Owns admission, sync/native-wait scopes, non-reentrant microtask checkpoints, and turn order. Each host / native-dispatch / TSFN / JS-timer callback finishes before its microtask checkpoint. Microtasks spawned by microtasks drain before the next queued task.

## SyncWait / native_sync

A sync native call holds `SyncWait` from the host start callback until result or exception. Other threads may enqueue and complete; this environment does not run JS or microtasks during the wait. `native_sync` delivers bytes on the waiting thread via `zev.Condition` — no JS task needed for the result.

One owner thread: `start` → use request pointer → `wait` → `finish`. Bytes readable until `finish` (once, after the read). A reduced deadline can turn a completed result into a timeout before `wait` delivers it; after `wait` returns, later deadline changes leave that result alone. Completion, cancel, and instance-wide cancel/deadline changes may run concurrently.

## host_wake

Internal bridge for components that need to wake a Driver. Apps use `Driver.run` / `runFor` / `attach` — no wake callbacks, no pumping. `set` / `drop` may run concurrently (including same instance ID); after active callbacks finish, effects for that ID follow slot-mutex reacquire order. Neither from a host-wake callback.

## Ownership / turns

Host supplies JS calls, exception handling, job drain. Every scope finishes while its runtime is alive. Scheduler state is owner-thread only; native completion/notification registries have their own sync. Root engine owns runtime admission/destruction and JS values in timer/dispatch adapters. `zev` alone owns the native timer heap.

Each turn: collect native readiness → at most one ready JS task → full microtask checkpoint. Fair rotate among host scripts, native dispatch, TSFN, due timers. FIFO within a source; order across sources unspecified. A future host `nextTick` belongs to the embedder and must enqueue a later task (not a Promise microtask / Node `process.nextTick`). This package does not claim full HTML or Node event-loop compatibility.

JSC runs Promise reactions inside the VM; QuickJS-family exposes an explicit job drain. The engine adapter enforces controllable task/checkpoint boundaries and tests the contract on all three backends.

## Test

```sh
zig build test
```

Pure scheduling / native-wait / notification contracts live here; real-engine ordering and lifecycle tests are in the root suite. Root `zig build test` also runs this suite and forwards `-Dtest-filter`.
