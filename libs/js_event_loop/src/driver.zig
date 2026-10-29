const std = @import("std");
const builtin = @import("builtin");
const zev = @import("zev");
const Scheduler = @import("scheduler.zig").Scheduler;

/// Owns native waiting, timer readiness, and browser-style task turns for one JavaScript environment.
pub const Driver = struct {
    pub const testing = DriverTesting;
    allocator: std.mem.Allocator,
    loop: *zev.Loop,
    scheduler: Scheduler = .{},
    state_mutex: zev.Mutex = .{},
    mode: Mode = .idle,
    stop_requested: bool = false,
    /// When true, keep VM/timer/task state but do not run turns or schedule the Host.
    /// Orthogonal to `mode`: attached+suspended is the Hide/Show keep-alive shape.
    suspended: bool = false,
    attached: ?Attached = null,
    scheduled: bool = false,
    scheduled_delay: ?u64 = null,
    /// Host.schedule / race soft-cancel pairs in flight. detach waits so Host may free context only after cancel returns.
    host_ops_in_flight: usize = 0,
    host_ops_cv: zev.Condition = .init,
    last_error: ?Error = null,
    test_now: ?u64 = null,

    const Mode = enum { idle, running, attached };

    const Attached = struct {
        host: Host,
        drive: *const fn (?*anyopaque) void,
        context: ?*anyopaque,
    };

    pub const Error = error{ AlreadyRunning, Attached, ScheduleFailed };

    pub const Hooks = struct {
        context: ?*anyopaque,
        before_turn: ?*const fn (?*anyopaque) bool = null,
        prepare: ?*const fn (?*anyopaque, u64) bool = null,
        finish_turn: ?*const fn (?*anyopaque) void = null,
        run_one_task: *const fn (?*anyopaque, Scheduler.TaskSource, u64) bool,
        checkpoint: *const fn (?*anyopaque) void,
        finish_task: ?*const fn (?*anyopaque) void = null,
        next_task_deadline: *const fn (?*anyopaque) ?u64,
        should_stop: ?*const fn (?*anyopaque) bool = null,
    };

    /// A platform event loop schedules `task` once after `delay_ms`. It replaces an earlier unexecuted task.
    /// `cancel` is soft: drop the pending task only; the Host must stay reusable for later `schedule` (suspend/resume). Hard teardown belongs to detach/destroy on the SDK side.
    /// Both `schedule` and `cancel` may run from any thread.
    /// `detach` waits for in-flight `schedule` (+ race soft-cancel) before its own `cancel`, so Host may free `context` only after that final cancel returns.
    pub const Host = struct {
        context: ?*anyopaque,
        schedule: *const fn (?*anyopaque, u64, *const fn (?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) bool,
        cancel: *const fn (?*anyopaque) callconv(.c) void,
    };

    pub fn create(allocator: std.mem.Allocator) !*Driver {
        const self = try allocator.create(Driver);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .loop = try zev.Loop.create(allocator) };
        return self;
    }

    /// The caller must first detach an attached driver and stop all threads using this driver.
    pub fn destroy(self: *Driver) void {
        self.detach();
        self.loop.destroy();
        self.host_ops_cv.deinit();
        self.state_mutex.deinit();
        self.allocator.destroy(self);
    }

    pub fn now(self: *const Driver) u64 {
        if (builtin.is_test) if (self.test_now) |current| return current;
        return zev.monotonicMilliseconds();
    }

    pub fn isAttached(self: *Driver) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.mode == .attached;
    }

    pub fn lastError(self: *Driver) ?Error {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.last_error;
    }

    /// Runs one complete browser turn and returns an absolute deadline, zero for immediately ready work, or null while idle.
    fn runOnce(self: *Driver, hooks: Hooks) ?u64 {
        if (self.hasFailure()) return null;
        if (self.isSuspended()) return null;
        // Returning false skips the turn and reports no pending work; host must wake when turns become possible again.
        if (hooks.before_turn) |before| if (!before(hooks.context)) return null;
        if (self.shouldStop(hooks)) return null;

        const current = self.now();

        const Adapter = struct {
            hooks: Hooks,
            now: u64,
            driver: *Driver,
            prepared: bool = false,
            fn prepare(context: ?*anyopaque) void {
                const self_adapter: *@This() = @ptrCast(@alignCast(context.?));
                self_adapter.prepared = if (self_adapter.hooks.prepare) |hook| hook(self_adapter.hooks.context, self_adapter.now) else true;
                if (!self_adapter.prepared) return;
                self_adapter.driver.loop.dispatchEvents(self_adapter.now);
            }
            fn task(context: ?*anyopaque, source: Scheduler.TaskSource) bool {
                const self_adapter: *@This() = @ptrCast(@alignCast(context.?));
                if (!self_adapter.prepared) return false;
                return self_adapter.hooks.run_one_task(self_adapter.hooks.context, source, self_adapter.now);
            }
            fn checkpoint(context: ?*anyopaque) void {
                const self_adapter: *@This() = @ptrCast(@alignCast(context.?));
                self_adapter.hooks.checkpoint(self_adapter.hooks.context);
            }
            fn finish(context: ?*anyopaque) void {
                const self_adapter: *@This() = @ptrCast(@alignCast(context.?));
                if (self_adapter.hooks.finish_task) |hook| hook(self_adapter.hooks.context);
            }
        };
        var adapter = Adapter{ .hooks = hooks, .now = current, .driver = self };
        _ = self.scheduler.runTurn(.{
            .context = &adapter,
            .prepare_native_events = Adapter.prepare,
            .run_one_task = Adapter.task,
            .checkpoint = Adapter.checkpoint,
            .finish_task = Adapter.finish,
        });
        if (adapter.prepared) if (hooks.finish_turn) |finish| finish(hooks.context);
        return self.nextDeadline(hooks);
    }

    /// Blocks the current thread until stopped. It cannot run while attached to a platform loop.
    pub fn run(self: *Driver, hooks: Hooks) Error!void {
        try self.beginRun();
        defer self.endRun();
        while (!self.shouldStop(hooks)) {
            if (self.isSuspended()) {
                const seen = self.loop.wakeGeneration();
                _ = self.loop.waitForWake(seen, null);
                continue;
            }
            const seen = self.loop.wakeGeneration();
            const next = self.runOnce(hooks);
            if (self.shouldStop(hooks)) break;
            if (self.isSuspended()) continue;
            const current = self.now();
            const timeout = if (next) |deadline| if (deadline == 0 or deadline <= current) 0 else deadline - current else null;
            _ = self.loop.waitForWake(seen, timeout);
        }
    }

    /// Runs until the timeout expires, preserving the same self-contained waiting behavior as `run`.
    pub fn runFor(self: *Driver, hooks: Hooks, timeout_ms: u64) Error!void {
        const deadline = std.math.add(u64, self.now(), timeout_ms) catch std.math.maxInt(u64);
        try self.beginRun();
        defer self.endRun();
        var first_turn = true;
        while (!self.shouldStop(hooks) and (first_turn or self.now() < deadline)) {
            first_turn = false;
            if (self.isSuspended()) {
                const current = self.now();
                if (current >= deadline) break;
                const seen = self.loop.wakeGeneration();
                _ = self.loop.waitForWake(seen, deadline - current);
                continue;
            }
            const seen = self.loop.wakeGeneration();
            const next = self.runOnce(hooks);
            const current = self.now();
            if (self.shouldStop(hooks) or current >= deadline) break;
            if (self.isSuspended()) continue;
            const own = if (next) |candidate| if (candidate == 0 or candidate <= current) 0 else candidate - current else null;
            const remaining = deadline - current;
            const timeout = if (own) |delay| @min(delay, remaining) else remaining;
            _ = self.loop.waitForWake(seen, timeout);
        }
    }

    /// Ends the active blocking run, or the next one when none is active; the run that ends consumes the request, and `attach` discards one made before it. While attached it stops platform driving until `detach` and a later `attach`, and `detach` discards it.
    pub fn requestStop(self: *Driver) void {
        self.state_mutex.lock();
        self.stop_requested = true;
        self.state_mutex.unlock();
        self.wake();
    }

    /// Pause JS scheduling without detaching the Host or clearing timers/tasks/VM state.
    /// Safe from any thread. An in-flight turn finishes; new turns and Host schedules stay gated until `resumeScheduling`.
    /// Soft-cancels a pending Host schedule via `Host.cancel` (must remain reusable). Does not wait out an active sync wait — the wait itself is not torn, and completions may still wake the owner.
    pub fn suspendScheduling(self: *Driver) void {
        self.state_mutex.lock();
        self.suspended = true;
        const attached = self.attached;
        const was_scheduled = self.scheduled;
        self.scheduled = false;
        self.scheduled_delay = null;
        self.state_mutex.unlock();
        if (was_scheduled) if (attached) |entry| entry.host.cancel(entry.host.context);
        // Wake blocking `run`/`runFor` waiters so they observe the suspended gate instead of sleeping on a timer deadline.
        self.loop.wake();
    }

    /// Resume scheduling after `suspendScheduling`. Safe from any thread.
    /// Does not clear timers, tasks, binds, or globals. Re-schedules an attached Host immediately so overdue work catch-up uses real monotonic time.
    pub fn resumeScheduling(self: *Driver) void {
        self.state_mutex.lock();
        const was_suspended = self.suspended;
        self.suspended = false;
        // Attached Hide/Show: a stop_loop while suspended must not leave scheduleAttached permanently no-op (attached zombie). Resume wins and clears the stop latch.
        if (was_suspended and self.mode == .attached) self.stop_requested = false;
        self.state_mutex.unlock();
        if (!was_suspended) return;
        self.wake();
    }

    pub fn isSuspended(self: *Driver) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.suspended;
    }

    /// Scalar control-plane view for multi-instance ops dashboards. Best-effort across locks; lengths are not included here.
    pub const ControlSnapshot = struct {
        mode: u8,
        flags: u8,
    };

    /// bit0 suspended · bit1 attached · bit3 loop_failed · bit4 sync_wait (bit2 reserved; teardown is refused by the lease, not reported here).
    pub fn controlSnapshot(self: *Driver) ControlSnapshot {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        var flags: u8 = 0;
        if (self.suspended) flags |= 0b0000_0001;
        if (self.attached != null) flags |= 0b0000_0010;
        if (self.last_error != null) flags |= 0b0000_1000;
        if (self.scheduler.sync_wait_depth.load(.acquire) != 0) flags |= 0b0001_0000;
        const mode: u8 = switch (self.mode) {
            .idle => 0,
            .running => 1,
            .attached => 2,
        };
        return .{ .mode = mode, .flags = flags };
    }

    /// Wakes a blocking driver or schedules one attached platform callback. Calls may come from any thread.
    /// While suspended, only the wait primitive is woken; the Host is not scheduled until `resumeScheduling`.
    pub fn wake(self: *Driver) void {
        self.loop.wake();
        self.scheduleAttached(0);
    }

    /// Attaches the driver to a platform-owned owner thread. The platform invokes `drive`, whose implementation calls `runAttached` while its engine lease is held.
    /// Host.schedule runs outside `state_mutex` (same hygiene as wake/resume): Hosts may re-enter via JNI / CFRunLoop / TSFN.
    pub fn attach(self: *Driver, host: Host, drive: *const fn (?*anyopaque) void, context: ?*anyopaque) Error!void {
        self.state_mutex.lock();
        if (self.mode == .running) {
            self.state_mutex.unlock();
            return error.AlreadyRunning;
        }
        if (self.attached != null) {
            self.state_mutex.unlock();
            return error.Attached;
        }
        self.last_error = null;
        self.stop_requested = false;
        self.mode = .attached;
        self.attached = .{ .host = host, .drive = drive, .context = context };
        self.state_mutex.unlock();

        if (!self.scheduleAttachedUnlocked(0)) {
            self.state_mutex.lock();
            // Roll back only while this attach still owns the slot (detach may have raced).
            const still_ours = self.attached != null;
            if (still_ours) {
                self.attached = null;
                self.scheduled = false;
                self.scheduled_delay = null;
                self.mode = .idle;
            }
            self.state_mutex.unlock();
            // Only cancel if we still owned the slot. If detach raced, it already drained host_ops and cancelled.
            // Hosts that arm before returning false still need a soft cancel; race cancels already ran unlocked.
            if (still_ours) host.cancel(host.context);
            return error.ScheduleFailed;
        }
    }

    /// Must run on the platform owner thread. It never blocks and schedules the next needed platform callback itself.
    pub fn runAttached(self: *Driver, hooks: Hooks) void {
        self.state_mutex.lock();
        const usable = self.mode == .attached and self.attached != null and self.last_error == null and !self.suspended;
        self.state_mutex.unlock();
        if (!usable) return;
        const next = self.runOnce(hooks);
        if (self.isSuspended()) return;
        if (next) |deadline| {
            const current = self.now();
            self.scheduleAttached(if (deadline == 0 or deadline <= current) 0 else deadline - current);
        }
    }

    /// Must be called by the platform owner after it has excluded further callbacks.
    /// Waits for any in-flight Host.schedule / race soft-cancel pair so Host may free `context` only after this cancel returns.
    pub fn detach(self: *Driver) void {
        self.state_mutex.lock();
        const attached = self.attached;
        self.attached = null;
        self.scheduled = false;
        self.scheduled_delay = null;
        if (self.mode == .attached) {
            self.mode = .idle;
            self.stop_requested = false;
        }
        while (self.host_ops_in_flight != 0) {
            self.host_ops_cv.wait(&self.state_mutex);
        }
        self.state_mutex.unlock();
        if (attached) |entry| entry.host.cancel(entry.host.context);
    }

    fn beginRun(self: *Driver) Error!void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (self.last_error != null) return error.ScheduleFailed;
        if (self.mode == .attached) return error.Attached;
        if (self.mode == .running) return error.AlreadyRunning;
        if (self.scheduler.isTurnActive() or !self.scheduler.allowsQueuedWork()) return error.AlreadyRunning;
        self.mode = .running;
    }
    fn endRun(self: *Driver) void {
        self.state_mutex.lock();
        self.mode = .idle;
        self.stop_requested = false;
        self.state_mutex.unlock();
    }
    fn shouldStop(self: *Driver, hooks: Hooks) bool {
        self.state_mutex.lock();
        const requested = self.stop_requested;
        const mode = self.mode;
        const failed = self.last_error != null;
        self.state_mutex.unlock();
        if (failed) return true;
        if (requested and mode != .idle) return true;
        return if (hooks.should_stop) |stop| stop(hooks.context) else false;
    }
    fn hasFailure(self: *Driver) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.last_error != null;
    }
    fn nextDeadline(self: *Driver, hooks: Hooks) ?u64 {
        const native = self.loop.nextDeadline();
        const host = hooks.next_task_deadline(hooks.context);
        if (native) |deadline| if (deadline == 0) return 0;
        if (host) |deadline| if (deadline == 0) return 0;
        if (native) |left| if (host) |right| return @min(left, right) else return left;
        return host;
    }
    fn scheduleAttached(self: *Driver, delay_ms: u64) void {
        _ = self.scheduleAttachedUnlocked(delay_ms);
    }
    /// Releases `state_mutex` before Host.schedule and before any race soft-cancel (R2/R3: Host must not run under Driver locks).
    /// Increments `host_ops_in_flight` across schedule + optional race cancel so detach cannot free Host context underneath.
    fn scheduleAttachedUnlocked(self: *Driver, delay_ms: u64) bool {
        self.state_mutex.lock();
        const attached = self.attached orelse {
            self.state_mutex.unlock();
            return true;
        };
        if (self.last_error != null) {
            self.state_mutex.unlock();
            return false;
        }
        if (self.suspended or self.stop_requested) {
            self.state_mutex.unlock();
            return true;
        }
        if (self.scheduled and (self.scheduled_delay orelse 0) == 0) {
            self.state_mutex.unlock();
            return true;
        }
        if (self.scheduled and delay_ms != 0) {
            self.state_mutex.unlock();
            return true;
        }
        const host = attached.host;
        self.host_ops_in_flight += 1;
        self.state_mutex.unlock();
        const ok = host.schedule(host.context, delay_ms, attachedTrampoline, self);
        self.state_mutex.lock();
        // If detach/suspend raced, ignore a late schedule success and soft-cancel outside the lock.
        if (self.attached == null or self.suspended or self.stop_requested or self.last_error != null) {
            const failed = self.last_error != null;
            self.state_mutex.unlock();
            if (ok) host.cancel(host.context);
            self.state_mutex.lock();
            std.debug.assert(self.host_ops_in_flight != 0);
            self.host_ops_in_flight -= 1;
            self.host_ops_cv.broadcast();
            self.state_mutex.unlock();
            return !failed;
        }
        self.scheduled = ok;
        self.scheduled_delay = if (ok) delay_ms else null;
        if (!ok) self.last_error = error.ScheduleFailed;
        std.debug.assert(self.host_ops_in_flight != 0);
        self.host_ops_in_flight -= 1;
        self.host_ops_cv.broadcast();
        self.state_mutex.unlock();
        return ok;
    }
    fn attachedTrampoline(context: ?*anyopaque) callconv(.c) void {
        const self: *Driver = @ptrCast(@alignCast(context.?));
        self.state_mutex.lock();
        const attached = self.attached;
        const suspended = self.suspended;
        self.scheduled = false;
        self.scheduled_delay = null;
        self.state_mutex.unlock();
        if (suspended) return;
        if (attached) |entry| entry.drive(entry.context);
    }

    /// Engine adapters may advance one already-owned turn without receiving a deadline or clock input.
    pub const integration = struct {
        pub fn runOne(driver: *Driver, hooks: Hooks) void {
            _ = driver.runOnce(hooks);
        }
    };
};

/// A one-shot native timer owned by a Driver.
pub const Timer = struct {
    raw: zev.Timer = .{},
    driver: ?*Driver = null,
    context: ?*anyopaque = null,
    callback: ?*const fn (?*anyopaque, *Timer) void = null,

    pub fn init(self: *Timer, driver: *Driver, context: ?*anyopaque, callback: *const fn (?*anyopaque, *Timer) void) void {
        self.driver = driver;
        self.context = context;
        self.callback = callback;
        self.raw.init(driver.loop, self, onTimer);
    }
    pub fn reserve(self: *Timer) !void {
        try self.raw.reserve();
    }
    pub fn startAt(self: *Timer, deadline_ms: u64) !void {
        try self.raw.startAt(deadline_ms);
        if (self.driver) |driver| driver.wake();
    }
    pub fn startAfter(self: *Timer, delay_ms: u64) !void {
        if (self.raw.loop == null) return error.Closed;
        const driver = self.driver orelse return error.Closed;
        return self.startAt(std.math.add(u64, driver.now(), delay_ms) catch std.math.maxInt(u64));
    }
    pub fn cancel(self: *Timer) bool {
        const cancelled = self.raw.cancel();
        if (cancelled) if (self.driver) |driver| driver.wake();
        return cancelled;
    }
    pub fn close(self: *Timer) void {
        self.raw.close();
        self.driver = null;
    }
    pub fn isActive(self: *Timer) bool {
        return self.raw.isActive();
    }
    /// Returns the absolute monotonic deadline while the timer is active. The caller must own the timer.
    pub fn deadline(self: *const Timer) u64 {
        return self.raw.deadline_ms;
    }
    fn onTimer(context: ?*anyopaque, _: *zev.Timer) void {
        const self: *Timer = @ptrCast(@alignCast(context.?));
        if (self.callback) |callback| callback(self.context, self);
    }
};

/// A coalescing native notification owned by a Driver.
pub const Notifier = struct {
    raw: zev.Notifier = .{},
    driver: ?*Driver = null,
    context: ?*anyopaque = null,
    callback: ?*const fn (?*anyopaque, *Notifier) void = null,

    pub fn init(self: *Notifier, driver: *Driver, context: ?*anyopaque, callback: *const fn (?*anyopaque, *Notifier) void) void {
        self.driver = driver;
        self.context = context;
        self.callback = callback;
        self.raw.init(driver.loop, self, onNotifier);
    }
    pub fn notify(self: *Notifier) bool {
        const notified = self.raw.notify();
        if (notified) if (self.driver) |driver| driver.wake();
        return notified;
    }
    pub fn close(self: *Notifier) void {
        self.raw.close();
        self.driver = null;
    }
    fn onNotifier(context: ?*anyopaque, _: *zev.Notifier) void {
        const self: *Notifier = @ptrCast(@alignCast(context.?));
        if (self.callback) |callback| callback(self.context, self);
    }
};

const DriverTesting = if (builtin.is_test) struct {
    /// Executes one complete turn and returns its internal deadline for assertions.
    pub fn runOnce(driver: *Driver, hooks: Driver.Hooks) ?u64 {
        return driver.runOnce(hooks);
    }

    /// Advances a driver's test-only monotonic clock and executes one complete turn.
    pub fn advance(driver: *Driver, hooks: Driver.Hooks, now: u64) ?u64 {
        driver.test_now = if (driver.test_now) |current| @max(current, now) else now;
        return driver.runOnce(hooks);
    }

    /// Dispatches native readiness without selecting a JavaScript task.
    pub fn dispatchEvents(driver: *Driver, now: u64) void {
        driver.test_now = if (driver.test_now) |current| @max(current, now) else now;
        driver.loop.dispatchEvents(driver.test_now.?);
    }
} else struct {};

pub const testing = DriverTesting;
