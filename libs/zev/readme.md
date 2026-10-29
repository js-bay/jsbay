# zev

A small event loop and notification library for Zig 0.17. zev provides cross-thread notifications, one-shot timers, waiting, clocks, and synchronization primitives. Callbacks run on the thread driving the loop; host applications own their task queues and scheduling policy.

| API | Purpose |
| --- | --- |
| `Loop` | Dispatch notifications, wait until the next deadline, wake, and stop |
| `Notifier` | Notify the loop from other threads without allocating; repeated notifications may coalesce |
| `Timer` | Schedule a one-shot callback using a shared deadline heap |
| `Waiter` | Wait for a generation counter to change |
| `Mutex`, `Condition` | Synchronize shared state and wait for changes |
| Clock and sleep functions | Read monotonic or realtime milliseconds, or sleep |

## Build integration

Add a local path dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .zev = .{ .path = "path/to/zev" },
},
```

Add the module to your executable in `build.zig`:

```zig
const dependency = b.dependency("zev", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zev", dependency.module("zev"));
exe.root_module.link_libc = true;
```

Create a loop with `Loop.create(allocator)`. The caller supplies the allocator and receives allocation errors explicitly. Platform-specific native dependencies are listed below.

## API compatibility

This release changes the public API: `Async.send()` is now `Notifier.notify()`, loop construction is `Loop.create(allocator)` with `destroy()`, and `Condition.waitTimeout()` returns `.notified` or `.timed_out`. Update callers rather than relying on compatibility aliases.

`Mutex` now uses native blocking synchronization and has a different layout. Rebuild Zig consumers and add `deinit()` to the owners of instance-local mutexes.

## Mutex lifetime

`Mutex` uses a blocking operating-system mutex. Construct it with `.{}` at its final address, then call `lock()`, `unlock()`, or `tryLock()`. Do not copy a mutex after construction or lock it recursively. An instance-owned mutex must be unlocked and have no remaining users or waiters before its owner calls `deinit()`. Process-wide mutexes may remain alive until process exit.

A condition wait releases the associated mutex while sleeping and reacquires it before returning. Always recheck the protected predicate in a loop, including after a timeout or notification.

OpenHarmony imports the mutex layout and `PTHREAD_MUTEX_INITIALIZER` from its SDK `pthread.h` during the build. The mutex stays inline, like the other POSIX targets; it does not allocate a handle or use a C mutex wrapper.

## Quick start

This program waits for a timer, invokes its callback on the calling thread, and stops the loop:

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

`run` keeps running until stopped, until `should_stop` returns true, or until an optional `deadline_ms` is reached. It does not exit merely because no timers remain.

## Driving the loop

All timers attached to a `Loop` share one indexed min-heap. By default, `runOnce` snapshots pending `Notifier` notifications and due timers, dispatches their callbacks, then calls an optional host `tick`. It never waits.

A host tick has this signature:

```zig
fn tick(ctx: ?*anyopaque, now_ms: u64) ?u64
```

Return the host's next absolute monotonic deadline, or `null` if it has none. Return `now_ms` while ready host work remains so that the loop does not sleep with work still queued.

`run` records the wake generation before doing work, then waits for the earliest deadline from its timers, the host tick, and `RunOptions.deadline_ms`. `wake()` interrupts the wait. `requestStop()` stops only a `run` that is currently active; a request made before `run()` has started does not stop the next run. The loop can be run again afterward. Both methods may be called from another thread.

Manual drivers can use `wakeGeneration()` and `waitForWake(seen, timeout_ms)` to observe wake notifications. These methods report only a wake change; they do not report that a callback has completed.

### Host-controlled dispatch

Set `RunOptions.event_dispatch = .host` when the host needs to choose where notifications run within its tick. In this mode, the host tick calls `loop.dispatchEvents(now_ms)` explicitly; zev does not dispatch automatically. Only one event batch is dispatched per `runOnce`, even if the host calls `dispatchEvents` again.

An external event loop can also call `dispatchEvents(now_ms)` directly and use `nextDeadline()` to arrange its next wake:

- An absolute timestamp means a timer is scheduled for that time.
- `0` means a notification is ready and another turn should run immediately.
- `null` means there is no scheduled or ready notification.

Keep timestamps in one monotonic clock domain. `startAfter` reads zev's system monotonic clock; use `startAt` when supplying timestamps from an external clock. Direct calls to `dispatchEvents` do not wait. In manual mode, the host decides whether and when to drive another turn; `requestStop()` does not add a separate manual-mode stop state.

## Notifications

Initialize a `Notifier` on the loop's owning thread with a callback of type `fn (?*anyopaque, *zev.Notifier) void`. Other threads may then call `notify()`:

```zig
var notification: zev.Notifier = .{};
notification.init(loop, &state, State.onNotify);
// From a notifying thread, while the handle and loop are alive:
const accepted = notification.notify();
```

`notify` returns `false` after the handle has been closed. It does not allocate and carries no payload. Multiple notifications may produce a single callback, so callback counts are not message counts. Store payloads in a queue or other shared state owned by your application.

The callback runs on the thread driving the loop, outside the loop's lock. Calling `notify()` again from a callback schedules a later turn rather than recursively invoking the callback.

## Timers

Initialize a `Timer` with a callback of type `fn (?*anyopaque, *zev.Timer) void`, then schedule it with:

- `startAfter(delay_ms)`: wait at least this many milliseconds from the current system monotonic time.
- `startAt(deadline_ms)`: use an absolute monotonic timestamp.
- `cancel()`: remove a pending callback; returns whether a scheduled or ready timer was cancelled.
- `isActive()`: report whether the timer is scheduled or ready to be dispatched.
- `close()`: cancel the timer and detach it from the loop.

Timers are one-shot and become inactive before their callbacks run. Restarting an active timer replaces its deadline. To repeat a timer, call `startAt` or `startAfter` again and choose the interval policy in your application.

Timers with equal deadlines are dispatched in the order they were scheduled for that deadline. A timer scheduled or restarted inside a callback waits for a later dispatch turn, including when its delay is zero. A callback may cancel or close another timer that is ready but has not yet been invoked.

Starting an unreserved timer may allocate to grow the shared heap. `reserve()` reserves capacity for a handle without scheduling it. The reservation lasts until `close`, allowing subsequent starts on that handle without heap growth. If reservation or heap growth fails, an existing timer schedule is preserved. Dispatching already queued timers does not allocate.

## Ownership and shutdown

- Initialize, schedule, cancel, close, and drive handles on the loop's owning thread. Among handle operations, only `Notifier.notify` is cross-thread; `Loop.wake` and `Loop.requestStop` are also thread-safe.
- Initialize handles with `.{}`. Once initialized, keep their addresses stable: do not copy or move them.
- Stop and join all notifying threads before closing or freeing a `Notifier`. Keep the loop alive until those threads have finished.
- Callbacks run outside the loop's lock and may close and free their own handles. Reentrant drive attempts do not execute another turn.
- End all driving, waiting, and waking operations before calling `Loop.destroy`. Do not destroy the loop from a callback.
- `Loop.destroy` detaches remaining handles without invoking callbacks. It does not free application-owned handles or callback contexts.

## Waiter and synchronization

`Waiter` uses a generation counter to avoid losing a wake between checking shared state and waiting. Read the generation before checking the state, using the application's synchronization to protect that state:

```zig
const seen = waiter.generation();
if (!hasWork()) _ = waiter.waitUntilChange(seen, null);
```

`waitUntilChange(expected, timeout_ms)` returns `true` when the generation changes and `false` on timeout. A `null` timeout waits indefinitely. `signal()` wakes at least one waiter; `broadcast()` wakes all waiters. Recheck application state after waking.

Generations can wrap: compare them for equality rather than treating them as event counts. The Linux-family backend uses a 32-bit counter; other backends use a 64-bit counter. Construct a `Waiter` at its final storage address and do not copy or move it. All operations must finish before its `deinit`.

`Condition.waitTimeout` reacquires the supplied `Mutex` before returning and yields `.notified` or `.timed_out`. `.notified` only means a notification was observed; while still holding the mutex, recheck the shared condition before proceeding.

## Native backends

Waiting, clocks, and sleep call operating-system APIs directly. They do not require a `std.Io` instance or initialize `std.Io.Threaded`. zev still uses the Zig standard library for allocators, atomics, and system declarations.

| Platform | Mutex | Waiting and waking | Clocks and sleep | Native dependency |
| --- | --- | --- | --- | --- |
| macOS, iOS | pthread mutex | pthread condition variables; relative timed waits | `clock_gettime(CLOCK_MONOTONIC)`, `nanosleep` | libc |
| Linux, Android | pthread mutex | `FUTEX_WAIT`, `FUTEX_WAKE` | Linux clock and sleep system calls | libc and kernel interfaces |
| OpenHarmony | SDK pthread mutex through a translated SDK header | `FUTEX_WAIT`, `FUTEX_WAKE` | Linux clock and sleep system calls | SDK headers, libc, and kernel interfaces |
| Windows | exclusive `SRWLOCK` | `SRWLOCK`, `CONDITION_VARIABLE` | `GetTickCount64`, `GetSystemTimeAsFileTime`, `Sleep` | `kernel32` |

Standalone OpenHarmony builds require `-Dohos-sysroot=<sdk-native-sysroot>`. For the stress executable, also pass `-Dohos-clang=<sdk-clang>`. An embedding build configures the shared `zev` module using `@import("zev").build_support_api.configureOhosMutex(b, module, target, sysroot)`; this adds the SDK include paths and the translated pthread binding without passing SDK options through every intermediate dependency.

`monotonicMilliseconds()` is suitable for deadlines. `realtimeMilliseconds()` reads wall-clock time and can change when the system clock is adjusted. `sleepMilliseconds()` suspends the calling thread.

## Testing

Run from the package directory:

```sh
zig build test
zig build stress -Doptimize=ReleaseFast
```

Add `-Dtsan=true` to enable ThreadSanitizer. Behavioral tests cover waiting and waking, synchronization, timer ordering and cancellation, cross-thread notifications, host-driven dispatch, reentrancy, and handle lifetimes. The stress executable checks native mutex lifecycle, `tryLock`, protected updates, and condition broadcasts, measures waiting-thread CPU time, then exercises one million signals from four producers, 100,000 zero-timeout waits, and 20,000 create/signal/wait lifecycles.

The platform test kit lives in [platform-test](platform-test/readme.md):

```sh
zig build platform-test -- run --case zev_stress --platform macos
zig build platform-test -- run --case zev_stress --all
```

The runner reports `PASS`, `FAIL`, or `SKIP` for each requested platform. Configuration uses the `ZEV_` prefix; see [config.env.example](platform-test/config.env.example) for toolchain and device settings.

When zev is used in the containing repository, its package-boundary checks run with the normal repository test suite.
