const std = @import("std");
const root = @import("root.zig");
const Waiter = root.Waiter;
const Mutex = @import("sync.zig").Mutex;

pub const RunOptions = struct {
    pub const EventDispatch = enum { automatic, host };

    ctx: ?*anyopaque = null,
    /// Performs one host-owned turn and returns its next absolute monotonic wake time. Return the current time while ready work remains; return null only when no host deadline is pending.
    tick: ?*const fn (?*anyopaque, u64) ?u64 = null,
    should_stop: ?*const fn (?*anyopaque) bool = null,
    deadline_ms: ?u64 = null,
    event_dispatch: EventDispatch = .automatic,
    /// Max Notifier+Timer callbacks to invoke in one dispatch turn. `null` means unlimited (default), so existing callers keep draining a full ready snapshot. Notifiers are drained before timers; exhaustion leaves remaining ready work queued and makes `runOnce` report an immediate deadline.
    dispatch_budget: ?usize = null,
    /// Optional wall/virtual-time cap for one dispatch turn, measured with `Loop.nowMs` from the turn start. `null` means no time limit (default). A limit of `0` prevents any callback in that turn (same idea as `dispatch_budget = 0`).
    dispatch_time_budget_ms: ?u64 = null,
};

pub const Notifier = struct {
    const State = enum { idle, pending, ready, executing, closed };

    loop: ?*Loop = null,
    ctx: ?*anyopaque = null,
    callback: ?*const fn (?*anyopaque, *Notifier) void = null,
    state: State = .closed,
    again: bool = false,
    registered_next: ?*Notifier = null,
    queue_next: ?*Notifier = null,

    pub fn init(self: *Notifier, loop: *Loop, ctx: ?*anyopaque, callback: *const fn (?*anyopaque, *Notifier) void) void {
        self.* = .{ .loop = loop, .ctx = ctx, .callback = callback, .state = .idle };
        loop.registerNotifier(self);
    }

    /// Thread-safe and allocation-free. Multiple notifications before a dispatch are represented by one callback.
    pub fn notify(self: *Notifier) bool {
        const loop = self.loop orelse return false;
        loop.events_mutex.lock();
        defer loop.events_mutex.unlock();
        switch (self.state) {
            .closed => return false,
            .idle => {
                loop.appendNotifierPendingLocked(self);
                loop.wakeForEvent();
            },
            .pending => {},
            .ready => {
                // Coalesce while already marked for another turn; first again still wakes.
                if (!self.again) {
                    self.again = true;
                    loop.wakeForEvent();
                }
            },
            .executing => {
                loop.appendNotifierPendingLocked(self);
                loop.wakeForEvent();
            },
        }
        return true;
    }

    /// Call from the owning thread after all sending threads have joined.
    pub fn close(self: *Notifier) void {
        const loop = self.loop orelse return;
        loop.events_mutex.lock();
        defer loop.events_mutex.unlock();
        if (self.state == .closed) return;
        loop.removeNotifierQueueLocked(self);
        loop.removeNotifierRegisteredLocked(self);
        self.state = .closed;
        self.again = false;
        self.loop = null;
    }
};

pub const Timer = struct {
    const State = enum { idle, heap, ready, closed };

    loop: ?*Loop = null,
    ctx: ?*anyopaque = null,
    callback: ?*const fn (?*anyopaque, *Timer) void = null,
    state: State = .closed,
    deadline_ms: u64 = 0,
    sequence: u64 = 0,
    heap_index: usize = 0,
    reserved: bool = false,
    registered_next: ?*Timer = null,
    registered_prev: ?*Timer = null,
    ready_next: ?*Timer = null,

    pub fn init(self: *Timer, loop: *Loop, ctx: ?*anyopaque, callback: *const fn (?*anyopaque, *Timer) void) void {
        self.* = .{ .loop = loop, .ctx = ctx, .callback = callback, .state = .idle };
        loop.registerTimer(self);
    }

    /// Schedules a one-shot callback at an absolute monotonic timestamp.
    pub fn startAt(self: *Timer, deadline_ms: u64) !void {
        const loop = self.loop orelse return error.Closed;
        loop.events_mutex.lock();
        defer loop.events_mutex.unlock();
        if (self.state == .closed) return error.Closed;
        if (!self.reserved) {
            const extra: usize = if (self.state == .heap) 0 else 1;
            try loop.ensureTimerCapacityLocked(loop.timer_heap.items.len + loop.reserved_timer_count + extra);
        }
        loop.removeTimerScheduleLocked(self);
        self.deadline_ms = deadline_ms;
        self.sequence = loop.next_timer_sequence;
        loop.next_timer_sequence +%= 1;
        self.state = .heap;
        self.heap_index = loop.timer_heap.items.len;
        loop.timer_heap.appendAssumeCapacity(self);
        loop.siftTimerUpLocked(self.heap_index);
        loop.wakeForEvent();
    }

    /// Reserve heap capacity for this handle without scheduling it. The reservation remains until close, so later startAt calls cannot fail because the shared heap needs to grow.
    pub fn reserve(self: *Timer) !void {
        const loop = self.loop orelse return error.Closed;
        loop.events_mutex.lock();
        defer loop.events_mutex.unlock();
        if (self.state == .closed) return error.Closed;
        if (self.reserved) return;
        try loop.ensureTimerCapacityLocked(loop.timer_heap.items.len + loop.reserved_timer_count + 1);
        self.reserved = true;
        loop.reserved_timer_count += 1;
    }

    pub fn startAfter(self: *Timer, delay_ms: u64) !void {
        const loop = self.loop orelse return error.Closed;
        const now = loop.nowMs();
        return self.startAt(std.math.add(u64, now, delay_ms) catch std.math.maxInt(u64));
    }

    pub fn cancel(self: *Timer) bool {
        const loop = self.loop orelse return false;
        loop.events_mutex.lock();
        defer loop.events_mutex.unlock();
        if (self.state != .heap and self.state != .ready) return false;
        loop.removeTimerScheduleLocked(self);
        return true;
    }

    pub fn close(self: *Timer) void {
        const loop = self.loop orelse return;
        loop.events_mutex.lock();
        defer loop.events_mutex.unlock();
        if (self.state == .closed) return;
        loop.removeTimerScheduleLocked(self);
        loop.removeTimerRegisteredLocked(self);
        if (self.reserved) {
            self.reserved = false;
            std.debug.assert(loop.reserved_timer_count != 0);
            loop.reserved_timer_count -= 1;
        }
        self.state = .closed;
        self.loop = null;
    }

    pub fn isActive(self: *Timer) bool {
        const loop = self.loop orelse return false;
        loop.events_mutex.lock();
        defer loop.events_mutex.unlock();
        return self.state == .heap or self.state == .ready;
    }
};

pub const Loop = struct {
    const RunState = enum(u8) { idle, running, stopped };

    allocator: std.mem.Allocator,
    waiter: Waiter = .init,
    run_state: std.atomic.Value(RunState) = .init(.idle),
    /// Thread that creates or last drives the loop. Used to skip redundant wakes: the owner cannot be blocked in `waitForWake` on this loop while calling in.
    owner_thread: std.atomic.Value(u64) = .init(0),
    events_mutex: Mutex = .{},
    notifier_registered: ?*Notifier = null,
    notifier_pending_head: ?*Notifier = null,
    notifier_pending_tail: ?*Notifier = null,
    notifier_ready_head: ?*Notifier = null,
    notifier_ready_tail: ?*Notifier = null,
    timer_registered: ?*Timer = null,
    timer_heap: std.ArrayList(*Timer) = .empty,
    timer_ready_head: ?*Timer = null,
    timer_ready_tail: ?*Timer = null,
    next_timer_sequence: u64 = 0,
    reserved_timer_count: usize = 0,
    dispatching_events: bool = false,
    running_once: bool = false,
    turn_active: bool = false,
    events_dispatched: bool = false,
    clock_ctx: ?*anyopaque = null,
    clock_fn: ?*const fn (?*anyopaque) u64 = null,

    pub fn create(allocator: std.mem.Allocator) !*Loop {
        const loop = try allocator.create(Loop);
        errdefer allocator.destroy(loop);
        loop.* = .{ .allocator = allocator };
        loop.bindOwnerThread();
        return loop;
    }

    pub fn destroy(self: *Loop) void {
        self.events_mutex.lock();
        var notifier = self.notifier_registered;
        while (notifier) |handle| {
            notifier = handle.registered_next;
            handle.state = .closed;
            handle.loop = null;
            handle.again = false;
            handle.registered_next = null;
            handle.queue_next = null;
        }
        var timer = self.timer_registered;
        while (timer) |handle| {
            timer = handle.registered_next;
            handle.state = .closed;
            handle.loop = null;
            handle.registered_next = null;
            handle.registered_prev = null;
            handle.ready_next = null;
            handle.reserved = false;
        }
        self.notifier_registered = null;
        self.notifier_pending_head = null;
        self.notifier_pending_tail = null;
        self.notifier_ready_head = null;
        self.notifier_ready_tail = null;
        self.timer_registered = null;
        self.reserved_timer_count = 0;
        self.timer_ready_head = null;
        self.timer_ready_tail = null;
        self.timer_heap.deinit(self.allocator);
        self.events_mutex.unlock();
        self.events_mutex.deinit();
        self.waiter.deinit();
        self.allocator.destroy(self);
    }

    /// Install a monotonic clock used by `nowMs`, timer due checks, time budgets, `Timer.startAfter`, `runOnce`, and `run`. Pass a null function to restore the system monotonic clock.
    /// Not synchronized: call from the owner/test thread with no concurrent `nowMs` / dispatch / `startAfter`. A frozen virtual clock means `dispatch_time_budget_ms` will not elapse unless the harness advances the clock (count budgets still apply).
    /// Prefer `runOnce` / `dispatchEvents` over blocking `run` when advancing time from the same thread; under a custom clock, `run` waits only for an external wake.
    pub fn setClock(self: *Loop, ctx: ?*anyopaque, now: ?*const fn (?*anyopaque) u64) void {
        self.clock_ctx = ctx;
        self.clock_fn = now;
    }

    pub fn nowMs(self: *const Loop) u64 {
        if (self.clock_fn) |clock| return clock(self.clock_ctx);
        return root.monotonicMilliseconds();
    }

    fn bindOwnerThread(self: *Loop) void {
        self.owner_thread.store(@intCast(std.Thread.getCurrentId()), .release);
    }

    pub fn isOwnerThread(self: *const Loop) bool {
        const owner = self.owner_thread.load(.acquire);
        if (owner == 0) return false;
        return owner == @as(u64, @intCast(std.Thread.getCurrentId()));
    }

    /// Skip the waiter signal when the owner thread is already driving this loop (`run` / `beginRun` / `runOnce` / `dispatchEvents`): it cannot be blocked in `waitForWake` for this loop while calling in. If the owner is idle, always signal so a create-thread `notify` cannot starve another thread blocked in `waitForWake`. Full mutex elision on the owner is unsafe because cross-thread `Notifier.notify` mutates the same queues.
    fn wakeForEvent(self: *Loop) void {
        if (self.isOwnerThread()) {
            // `.running` and `.stopped` both mean a beginRun session is still open (endRun not yet called).
            if (self.run_state.load(.seq_cst) != .idle) return;
            if (self.running_once or self.dispatching_events or self.turn_active) return;
        }
        self.wake();
    }

    /// Mark this thread as driving the loop for the duration of a blocking run (including waits).
    /// Returns false if another driver already called `beginRun` (state was not idle).
    /// External drivers such as `js_event_loop.Driver.run` / `runFor` must pair a successful call with `endRun`.
    pub fn beginRun(self: *Loop) bool {
        self.bindOwnerThread();
        return self.run_state.cmpxchgStrong(.idle, .running, .seq_cst, .seq_cst) == null;
    }
    /// Clears the driving session started by `beginRun` (from `.running` or `.stopped`).
    pub fn endRun(self: *Loop) void {
        self.run_state.store(.idle, .seq_cst);
    }
    /// True while a `beginRun` session is open (`.running` or `.stopped` after `requestStop`, until `endRun`).
    pub fn isRunning(self: *const Loop) bool {
        return self.run_state.load(.seq_cst) != .idle;
    }
    pub fn requestStop(self: *Loop) void {
        _ = self.run_state.cmpxchgStrong(.running, .stopped, .seq_cst, .seq_cst);
        self.wakeForEvent();
    }
    fn isStopRequested(self: *const Loop) bool {
        return self.run_state.load(.seq_cst) == .stopped;
    }
    pub fn wake(self: *Loop) void {
        self.waiter.signal();
    }
    pub fn wakeGeneration(self: *Loop) u64 {
        return self.waiter.generation();
    }
    pub fn waitForWake(self: *Loop, seen: u64, timeout_ms: ?u64) bool {
        const finite: u64 = if (timeout_ms) |milliseconds| @min(milliseconds, @as(u64, std.math.maxInt(u32) - 1)) else return self.waiter.waitUntilChange(seen, null);
        return self.waiter.waitUntilChange(seen, finite);
    }

    /// Runs pending Notifier and due Timer callbacks using `nowMs()` for timer due checks.
    /// Time budgets also sample `nowMs()`; do not pass a separate host clock sample.
    /// Recursion only observes the outer dispatch; callbacks registered during this turn wait for another.
    pub fn dispatchEvents(self: *Loop) void {
        self.dispatchEventsLimited(null, null);
    }

    /// Like `dispatchEvents`, with optional count and time budgets. Timer due checks and time budgets both use `nowMs()`.
    pub fn dispatchEventsLimited(self: *Loop, budget: ?usize, time_budget_ms: ?u64) void {
        if (self.dispatching_events or (self.turn_active and self.events_dispatched)) return;
        if (self.turn_active) self.events_dispatched = true;
        self.bindOwnerThread();
        self.dispatchEventsForTurn(self.nowMs(), budget, time_budget_ms);
    }

    fn dispatchEventsForTurn(self: *Loop, now_ms: u64, budget: ?usize, time_budget_ms: ?u64) void {
        std.debug.assert(!self.dispatching_events);
        self.dispatching_events = true;
        defer self.dispatching_events = false;
        self.events_mutex.lock();
        self.snapshotEventsLocked(now_ms);
        self.events_mutex.unlock();
        var remaining = budget;
        // Sample the clock only when a time budget is active. Count-only and unlimited
        // drains must not pay clock_gettime (or virtual-clock) per callback.
        const turn_started: u64 = if (time_budget_ms != null) self.nowMs() else 0;
        self.runReadyNotifier(&remaining, time_budget_ms, turn_started);
        if (!self.isStopRequested()) self.runReadyTimers(&remaining, time_budget_ms, turn_started);
    }

    fn consumeBudget(remaining: *?usize) void {
        if (remaining.*) |*left| left.* -|= 1;
    }

    /// Returns false when the turn has exhausted its count and/or time budget.
    /// Does not read the clock unless `time_budget_ms` is set.
    fn budgetAllows(self: *Loop, remaining: *?usize, time_budget_ms: ?u64, turn_started: u64) bool {
        if (remaining.*) |left| if (left == 0) return false;
        if (time_budget_ms) |limit| if (self.nowMs() -% turn_started >= limit) return false;
        return true;
    }

    pub fn nextDeadline(self: *Loop) ?u64 {
        self.events_mutex.lock();
        defer self.events_mutex.unlock();
        if (self.notifier_pending_head != null or self.notifier_ready_head != null or self.timer_ready_head != null) return 0;
        if (self.timer_heap.items.len == 0) return null;
        return self.timer_heap.items[0].deadline_ms;
    }

    pub fn runOnce(self: *Loop, options: RunOptions) ?u64 {
        if (self.running_once or self.dispatching_events or self.turn_active) return self.nextDeadline();
        if (options.should_stop) |stop| if (stop(options.ctx)) return null;
        self.bindOwnerThread();
        self.running_once = true;
        defer self.running_once = false;
        self.turn_active = true;
        defer self.turn_active = false;
        self.events_dispatched = false;
        const now = self.nowMs();
        if (options.event_dispatch == .automatic) {
            self.events_dispatched = true;
            self.dispatchEventsForTurn(now, options.dispatch_budget, options.dispatch_time_budget_ms);
        }
        if (self.isStopRequested()) return self.nextDeadline();
        if (options.should_stop) |stop| if (stop(options.ctx)) return null;
        const host_deadline = if (options.tick) |tick| tick(options.ctx, now) else null;
        const timer_deadline = self.nextDeadline();
        if (self.hasPendingNotifier()) return now;
        if (host_deadline) |host| return if (timer_deadline) |timer| @min(host, timer) else host;
        return timer_deadline;
    }

    pub fn run(self: *Loop, options: RunOptions) void {
        if (self.running_once or self.dispatching_events or self.turn_active) return;
        if (!self.beginRun()) return;
        defer self.endRun();
        while (!self.isStopRequested()) {
            if (options.should_stop) |stop| if (stop(options.ctx)) break;
            const seen = self.wakeGeneration();
            const next = self.runOnce(options);
            if (self.isStopRequested()) break;
            if (options.should_stop) |stop| if (stop(options.ctx)) break;
            const now = self.nowMs();
            if (options.deadline_ms) |limit| if (now >= limit) break;
            var timeout: ?u64 = if (next) |deadline| if (deadline <= now) 0 else deadline - now else null;
            if (options.deadline_ms) |limit| {
                const remaining = if (limit <= now) 0 else limit - now;
                timeout = if (timeout) |current| @min(current, remaining) else remaining;
            }
            // A virtual clock must not translate virtual delays into real sleeps. When the next
            // deadline is still in the future under a custom clock, park only for an external wake
            // (notify / requestStop / wake) so the harness can advance time on another thread.
            if (self.clock_fn != null) {
                if (timeout == null or timeout.? > 0) {
                    _ = self.waitForWake(seen, null);
                    continue;
                }
            }
            _ = self.waitForWake(seen, timeout);
        }
    }

    fn registerNotifier(self: *Loop, handle: *Notifier) void {
        self.events_mutex.lock();
        defer self.events_mutex.unlock();
        handle.registered_next = self.notifier_registered;
        self.notifier_registered = handle;
    }
    fn appendNotifierPendingLocked(self: *Loop, handle: *Notifier) void {
        handle.state = .pending;
        handle.queue_next = null;
        if (self.notifier_pending_tail) |tail| tail.queue_next = handle else self.notifier_pending_head = handle;
        self.notifier_pending_tail = handle;
    }
    fn removeNotifierQueueLocked(self: *Loop, handle: *Notifier) void {
        self.removeNotifierFromQueueLocked(&self.notifier_pending_head, &self.notifier_pending_tail, handle);
        self.removeNotifierFromQueueLocked(&self.notifier_ready_head, &self.notifier_ready_tail, handle);
        handle.queue_next = null;
    }
    fn removeNotifierFromQueueLocked(_: *Loop, head: *?*Notifier, tail: *?*Notifier, target: *Notifier) void {
        var previous: ?*Notifier = null;
        var current = head.*;
        while (current) |handle| : (current = handle.queue_next) {
            if (handle != target) {
                previous = handle;
                continue;
            }
            const next = handle.queue_next;
            if (previous) |prior| prior.queue_next = next else head.* = next;
            if (tail.* == handle) tail.* = previous;
            return;
        }
    }
    fn removeNotifierRegisteredLocked(self: *Loop, target: *Notifier) void {
        var previous: ?*Notifier = null;
        var current = self.notifier_registered;
        while (current) |handle| : (current = handle.registered_next) {
            if (handle != target) {
                previous = handle;
                continue;
            }
            if (previous) |prior| prior.registered_next = handle.registered_next else self.notifier_registered = handle.registered_next;
            handle.registered_next = null;
            return;
        }
    }
    fn registerTimer(self: *Loop, handle: *Timer) void {
        self.events_mutex.lock();
        defer self.events_mutex.unlock();
        handle.registered_next = self.timer_registered;
        handle.registered_prev = null;
        if (self.timer_registered) |old_head| old_head.registered_prev = handle;
        self.timer_registered = handle;
    }
    fn removeTimerRegisteredLocked(self: *Loop, target: *Timer) void {
        if (target.registered_prev) |previous| previous.registered_next = target.registered_next else self.timer_registered = target.registered_next;
        if (target.registered_next) |next| next.registered_prev = target.registered_prev;
        target.registered_next = null;
        target.registered_prev = null;
    }
    fn timerBefore(left: *Timer, right: *Timer) bool {
        return left.deadline_ms < right.deadline_ms or (left.deadline_ms == right.deadline_ms and left.sequence < right.sequence);
    }
    fn siftTimerUpLocked(self: *Loop, start: usize) void {
        var index = start;
        while (index != 0) {
            const parent = (index - 1) / 2;
            if (!timerBefore(self.timer_heap.items[index], self.timer_heap.items[parent])) break;
            self.swapTimersLocked(index, parent);
            index = parent;
        }
    }
    fn siftTimerDownLocked(self: *Loop, start: usize) void {
        var index = start;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.timer_heap.items.len) return;
            const right = left + 1;
            const child = if (right < self.timer_heap.items.len and timerBefore(self.timer_heap.items[right], self.timer_heap.items[left])) right else left;
            if (!timerBefore(self.timer_heap.items[child], self.timer_heap.items[index])) return;
            self.swapTimersLocked(index, child);
            index = child;
        }
    }
    fn ensureTimerCapacityLocked(self: *Loop, wanted_len: usize) !void {
        if (self.timer_heap.capacity >= wanted_len) return;
        var capacity = @max(@as(usize, 8), self.timer_heap.capacity);
        while (capacity < wanted_len) capacity *= 2;
        const replacement = try self.allocator.alloc(*Timer, capacity);
        @memcpy(replacement[0..self.timer_heap.items.len], self.timer_heap.items);
        self.allocator.free(self.timer_heap.allocatedSlice());
        self.timer_heap.items.ptr = replacement.ptr;
        self.timer_heap.capacity = replacement.len;
    }
    fn swapTimersLocked(self: *Loop, left: usize, right: usize) void {
        const a = self.timer_heap.items[left];
        const b = self.timer_heap.items[right];
        self.timer_heap.items[left] = b;
        self.timer_heap.items[right] = a;
        a.heap_index = right;
        b.heap_index = left;
    }
    fn removeTimerHeapLocked(self: *Loop, handle: *Timer) void {
        const index = handle.heap_index;
        const last = self.timer_heap.pop().?;
        if (index < self.timer_heap.items.len) {
            self.timer_heap.items[index] = last;
            last.heap_index = index;
            self.siftTimerDownLocked(index);
            self.siftTimerUpLocked(last.heap_index);
        }
        handle.state = .idle;
    }
    fn removeTimerReadyLocked(self: *Loop, target: *Timer) void {
        var previous: ?*Timer = null;
        var current = self.timer_ready_head;
        while (current) |handle| : (current = handle.ready_next) {
            if (handle != target) {
                previous = handle;
                continue;
            }
            const next = handle.ready_next;
            if (previous) |prior| prior.ready_next = next else self.timer_ready_head = next;
            if (self.timer_ready_tail == handle) self.timer_ready_tail = previous;
            handle.ready_next = null;
            handle.state = .idle;
            return;
        }
    }
    fn removeTimerScheduleLocked(self: *Loop, handle: *Timer) void {
        switch (handle.state) {
            .heap => self.removeTimerHeapLocked(handle),
            .ready => self.removeTimerReadyLocked(handle),
            else => {},
        }
    }
    fn snapshotEventsLocked(self: *Loop, now_ms: u64) void {
        if (self.notifier_pending_head) |head| {
            if (self.notifier_ready_tail) |tail| tail.queue_next = head else self.notifier_ready_head = head;
            self.notifier_ready_tail = self.notifier_pending_tail;
            self.notifier_pending_head = null;
            self.notifier_pending_tail = null;
            var current: ?*Notifier = head;
            while (current) |handle| : (current = handle.queue_next) handle.state = .ready;
        }
        while (self.timer_heap.items.len != 0 and self.timer_heap.items[0].deadline_ms <= now_ms) {
            const timer = self.timer_heap.items[0];
            self.removeTimerHeapLocked(timer);
            timer.state = .ready;
            timer.ready_next = null;
            if (self.timer_ready_tail) |tail| tail.ready_next = timer else self.timer_ready_head = timer;
            self.timer_ready_tail = timer;
        }
    }
    fn runReadyNotifier(self: *Loop, remaining: *?usize, time_budget_ms: ?u64, turn_started: u64) void {
        // Fold idle restore into the next dequeue lock so a multi-callback drain pays one
        // mutex round-trip per callback instead of two. The final callback still needs a
        // trailing lock to leave `.idle` (P0 state-machine invariant).
        var previous: ?*Notifier = null;
        while (!self.isStopRequested()) {
            if (!self.budgetAllows(remaining, time_budget_ms, turn_started)) break;
            self.events_mutex.lock();
            if (previous) |prior| {
                if (prior.state == .executing) prior.state = .idle;
                previous = null;
            }
            const handle = self.notifier_ready_head orelse {
                self.events_mutex.unlock();
                return;
            };
            self.notifier_ready_head = handle.queue_next;
            if (self.notifier_ready_head == null) self.notifier_ready_tail = null;
            handle.queue_next = null;
            if (handle.again) {
                handle.again = false;
                self.appendNotifierPendingLocked(handle);
            } else handle.state = .executing;
            const callback = handle.callback.?;
            const ctx = handle.ctx;
            self.events_mutex.unlock();
            consumeBudget(remaining);
            callback(ctx, handle);
            previous = handle;
        }
        if (previous) |prior| {
            self.events_mutex.lock();
            if (prior.state == .executing) prior.state = .idle;
            self.events_mutex.unlock();
        }
    }
    fn runReadyTimers(self: *Loop, remaining: *?usize, time_budget_ms: ?u64, turn_started: u64) void {
        while (!self.isStopRequested()) {
            if (!self.budgetAllows(remaining, time_budget_ms, turn_started)) return;
            self.events_mutex.lock();
            const handle = self.timer_ready_head orelse {
                self.events_mutex.unlock();
                return;
            };
            self.timer_ready_head = handle.ready_next;
            if (self.timer_ready_head == null) self.timer_ready_tail = null;
            handle.ready_next = null;
            handle.state = .idle;
            const callback = handle.callback.?;
            const ctx = handle.ctx;
            self.events_mutex.unlock();
            consumeBudget(remaining);
            callback(ctx, handle);
        }
    }
    fn hasPendingNotifier(self: *Loop) bool {
        self.events_mutex.lock();
        defer self.events_mutex.unlock();
        return self.notifier_pending_head != null or self.notifier_ready_head != null;
    }
};
