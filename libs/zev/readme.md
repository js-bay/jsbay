# zev

A small event loop and notification library for Zig 0.17. Cross-thread notifications, one-shot timers, waiting, clocks, sync primitives. Callbacks run on the thread driving the loop; the host owns its task queues and scheduling policy.

| API | Purpose |
| --- | --- |
| `Loop` | Dispatch, wait, wake, stop; optional dispatch budgets; replaceable clock via `setClock` / `nowMs` |
| `Notifier` | Cross-thread notify without allocating; coalesces; returns to idle after dispatch unless re-armed |
| `Timer` | One-shot callback on a shared deadline heap |
| `Waiter` | Wait for a generation counter to change |
| `Mutex`, `Condition` | Shared-state sync |
| Clock / sleep | Monotonic or realtime ms, sleep; loop timers use `Loop.nowMs` |

## Build integration

Add a local path dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .zev = .{ .path = "path/to/zev" },
},
```

Wire it in `build.zig`:

```zig
const dependency = b.dependency("zev", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zev", dependency.module("zev"));
exe.root_module.link_libc = true;
```

`Loop.create(allocator)` — caller supplies the allocator and handles allocation errors. Platform deps are in Native backends below.

## API compatibility

Public API changes: `Async.send()` → `Notifier.notify()`, loop construction is `Loop.create` / `destroy`, `Condition.waitTimeout()` returns `.notified` or `.timed_out`. No compatibility aliases.

`Mutex` is a native blocking mutex with a different layout. Rebuild consumers; owners of instance-local mutexes need `deinit()`.

## Mutex lifetime

Construct with `.{}` at its final address, then `lock` / `unlock` / `tryLock`. Do not copy after construction or lock recursively. Unlock and drop waiters before `deinit()`. Process-wide mutexes may live until exit.

Condition wait releases the mutex while sleeping and reacquires before return. Always recheck the predicate in a loop.

OpenHarmony pulls mutex layout and `PTHREAD_MUTEX_INITIALIZER` from its SDK `pthread.h` at build time. Inline like other POSIX targets — no heap handle, no C wrapper.

## Quick start

Waits for a timer, runs its callback on the calling thread, stops:

```zig
const std = @import("std");
const zev = @import("zev");

pub fn main() !void {
    const loop = try zev.Loop.create(std.heap.page_allocator);
    defer loop.destroy();

    var timer: zev.Timer = .{};
    timer.init(loop, loop, onTimer);
    defer timer.close();

    try timer.startAfter(25);
    loop.run(.{});
}

fn onTimer(ctx: ?*anyopaque, _: *zev.Timer) void {
    const loop: *zev.Loop = @ptrCast(@alignCast(ctx.?));
    loop.requestStop();
}
```

`run` stops on `requestStop`, `should_stop`, or optional `deadline_ms` — not merely because no timers remain.

## Driving the loop

All timers on a `Loop` share one indexed min-heap. Default `runOnce`: snapshot pending Notifiers and due Timers → dispatch → optional host `tick`. Never waits.

Host tick:

```zig
fn tick(ctx: ?*anyopaque, now_ms: u64) ?u64
```

Return the host's next absolute monotonic deadline, or `null`. Return `now_ms` while ready host work remains so the loop does not sleep with work queued.

`run` records the wake generation, does work, then waits for the earliest of timer / host / `RunOptions.deadline_ms`. `wake()` interrupts. `requestStop()` only affects an active `run`; a request before `run()` starts does not stop the next one. Both are thread-safe.

Manual drivers: `wakeGeneration()` + `waitForWake(seen, timeout_ms)`. These report wake changes only, not callback completion.

### Host-controlled dispatch

`RunOptions.event_dispatch = .host`: host tick calls `dispatchEvents()` / `dispatchEventsLimited`; zev does not auto-dispatch. One batch per `runOnce` even if the host calls dispatch again. Automatic mode uses the same `dispatch_budget` / `dispatch_time_budget_ms`.

External loops can call `dispatchEvents()` and use `nextDeadline()`:

- absolute timestamp — timer scheduled
- `0` — ready work; run another turn now
- `null` — nothing ready or scheduled

Due checks and time budgets use `Loop.nowMs()` (system monotonic, or `setClock`). No separate host `now` on dispatch. Use `setClock` for a virtual clock, or `startAt` in the same domain as `nowMs`. Direct dispatch does not wait. In manual mode the host decides the next turn; `requestStop()` does not add a separate stop state.

### Dispatch budget

- `RunOptions.dispatch_budget` / `dispatch_time_budget_ms`, or `dispatchEventsLimited`
- default `null` = drain the full ready snapshot (no clock read unless a time budget is set)
- Notifiers before Timers within a turn
- budget exhausted → remaining work stays ready; `nextDeadline()` is `0`

### Clock

- `Loop.setClock(ctx, now_fn)` — source for `nowMs`, due checks, time budgets, `startAfter`, `runOnce`, `run`
- null function restores system clock
- call from the owner/test thread only (unsynchronized)
- custom clock: `run` waits for an external wake instead of sleeping a virtual delay as wall time

## Notifications

Init on the owning thread; callback type `fn (?*anyopaque, *zev.Notifier) void`. Other threads call `notify()`:

```zig
var notification: zev.Notifier = .{};
notification.init(loop, &state, State.onNotify);
// From a notifying thread, while the handle and loop are alive:
const accepted = notification.notify();
```

`notify` returns `false` after close. No alloc, no payload. Multiple notifies may yield one callback — store payloads in app-owned shared state.

State (owner dispatches; `notify` is the cross-thread entry):

- `idle` → `pending` on first notify
- further `pending` notifies coalesce (no extra wake)
- snapshot: `pending` → `ready`
- dispatch: `executing` (or back to `pending` if `again` was set while `ready`)
- after callback → `idle`, unless a nested `notify` already re-armed to `pending`

Wake skip: while the owner is driving (`run` / `beginRun` / `runOnce` / `dispatchEvents`), same-thread `notify` / timer starts skip `Waiter.signal`. External blocking drivers wrap their wait loop with `beginRun` / `endRun`. Remote threads still wake. Idle owner always wakes so a create-thread `notify` cannot starve a waiter on another thread. Explicit `Loop.wake()` always signals. Mutex stays on every notify (queues are shared).

Callback runs on the driving thread, outside the loop lock. `notify()` from a callback schedules a later turn, not a recursive call.

## Timers

Callback type `fn (?*anyopaque, *zev.Timer) void`. Schedule with:

- `startAfter(delay_ms)` — relative to `Loop.nowMs()`
- `startAt(deadline_ms)` — absolute monotonic
- `cancel()` — remove pending/ready; returns whether one was cancelled
- `isActive()` — scheduled or ready
- `close()` — cancel and detach

One-shot; inactive before the callback runs. Restart replaces the deadline. Equal deadlines dispatch in schedule order. A start/restart inside a callback waits for a later turn (including delay 0). A callback may cancel/close another ready-but-not-yet-run timer.

Unreserved start may grow the heap. `reserve()` holds capacity until `close`. Failed growth keeps an existing schedule. Dispatch of already-queued timers does not allocate.

## Ownership and shutdown

- Init / schedule / cancel / close / drive on the owning thread. Cross-thread among handles: only `Notifier.notify`. Also thread-safe: `Loop.wake`, `Loop.requestStop`.
- Init with `.{}`; keep addresses stable.
- Stop and join notifying threads before closing or freeing a `Notifier`; keep the loop alive until they finish.
- Callbacks run outside the loop lock and may close/free their own handles. Reentrant drive does not run another turn.
- Finish all drive / wait / wake before `Loop.destroy`. Do not destroy from a callback.
- `destroy` detaches remaining handles without invoking callbacks; does not free app-owned handles or contexts.

## Waiter and synchronization

Generation counter avoids losing a wake between checking state and waiting:

```zig
const seen = waiter.generation();
if (!hasWork()) _ = waiter.waitUntilChange(seen, null);
```

`waitUntilChange(expected, timeout_ms)` → `true` on generation change, `false` on timeout. `null` timeout waits forever. `signal()` wakes ≥1; `broadcast()` wakes all. Recheck state after waking.

Compare generations for equality (they wrap). Linux-family: 32-bit; others: 64-bit. Construct at final address; no copy/move. Finish all ops before `deinit`.

`Condition.waitTimeout` reacquires the mutex before return (`.notified` / `.timed_out`). Recheck the condition while holding the mutex.

## Native backends

OS APIs directly — no `std.Io` / `std.Io.Threaded`. Still uses Zig std for allocators, atomics, system decls.

| Platform | Mutex | Waiting and waking | Clocks and sleep | Native dependency |
| --- | --- | --- | --- | --- |
| macOS, iOS | pthread mutex | pthread cond; relative timed waits | `clock_gettime(CLOCK_MONOTONIC)`, `nanosleep` | libc |
| Linux, Android | pthread mutex | `FUTEX_WAIT` / `FUTEX_WAKE` | Linux clock / sleep syscalls | libc + kernel |
| OpenHarmony | SDK pthread via translated header | `FUTEX_WAIT` / `FUTEX_WAKE` | Linux clock / sleep syscalls | SDK headers, libc, kernel |
| Windows | exclusive `SRWLOCK` | `SRWLOCK`, `CONDITION_VARIABLE` | `GetTickCount64`, `GetSystemTimeAsFileTime`, `Sleep` | `kernel32` |

Standalone OpenHarmony: `-Dohos-sysroot=<sdk-native-sysroot>`; stress also needs `-Dohos-clang=<sdk-clang>`. Embeddings configure via `@import("zev").build_support_api.configureOhosMutex(b, module, target, sysroot)`.

`monotonicMilliseconds()` for deadlines. `realtimeMilliseconds()` is wall clock (can jump). `sleepMilliseconds()` sleeps the calling thread.

## Testing

```sh
zig build test
zig build bench -Doptimize=ReleaseFast
zig build stress -Doptimize=ReleaseFast
```

`-Dtsan=true` for ThreadSanitizer. Behavioral tests cover wait/wake, sync, timer order/cancel, cross-thread notify, host dispatch, reentrancy, lifetimes. Stress: native mutex lifecycle, `tryLock`, protected updates, cond broadcasts, waiting-thread CPU, 1M signals / 4 producers, 100k zero-timeout waits, 20k create/signal/wait cycles.

Platform kit: [platform-test](platform-test/readme.md)

```sh
zig build platform-test -- run --case zev_stress --platform macos
zig build platform-test -- run --case zev_stress --all
```

`PASS` / `FAIL` / `SKIP` per platform. Config prefix `ZEV_`; see [config.env.example](platform-test/config.env.example).

In the containing repo, package-boundary checks run with the normal test suite.
