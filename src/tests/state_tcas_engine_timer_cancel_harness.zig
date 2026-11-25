//! Timer cancellation exploration over a live engine and the production timer queue.

const std = @import("std");
const testing = std.testing;
const state_tcas = @import("state_tcas");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const sync = @import("zev");
const instance_map = @import("../runtime/instance_map.zig");

const Trace = struct {
    var mutex: sync.Mutex = .{};
    var bytes: [64]u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        mutex.lock();
        defer mutex.unlock();
        len = 0;
    }

    fn append(byte: u8) void {
        mutex.lock();
        defer mutex.unlock();
        std.debug.assert(len < bytes.len);
        bytes[len] = byte;
        len += 1;
    }

    fn snapshot(out: *[64]u8) []const u8 {
        mutex.lock();
        defer mutex.unlock();
        @memcpy(out[0..len], bytes[0..len]);
        return out[0..len];
    }
};

fn record(_: i32, args: value.NativeArgs) value.NativeResult {
    const token = args.toString(0) orelse return .undefined_val;
    defer value.freeString(token);
    if (token.len == 1) Trace.append(token[0]);
    return .undefined_val;
}

fn installRecorder(id: i32) void {
    value.registerFunction(id, null, "__stRecord__", &record);
}

const TimerCancelAct = enum {
    schedule_timers,
    cancel_pending,
    enqueue_cancel_task,
    advance,
};

/// Live engine model for cancellation before a deadline and after a sibling timer has started.
const TimerCancelWorld = struct {
    id: i32,
    created: bool = false,
    target_timer_id: i32 = 0,
    log: [6]TimerCancelAct = undefined,
    log_len: usize = 0,
    acts_buf: [4]TimerCancelAct = undefined,
    scheduled: bool = false,
    pending_cancelled: bool = false,
    cancel_task_enqueued: bool = false,
    advances: u8 = 0,
    bad_cancel_delivery: bool = false,
    bad_task_checkpoint: bool = false,
    saw_pending_cancel: bool = false,
    saw_cancel_after_sibling: bool = false,
    saw_sibling_delivery: bool = false,
    cancel_after_sibling_candidate: bool = false,

    fn hasTrace(byte: u8) bool {
        var snapshot: [64]u8 = undefined;
        return std.mem.indexOfScalar(u8, Trace.snapshot(&snapshot), byte) != null;
    }

    fn targetIsInReadyState(self: *@This(), expected: []const u8) bool {
        if (self.target_timer_id == 0) return false;
        const inst = instance_map.getInstance(self.id) orelse return false;
        const target = inst.timers.entries.get(self.target_timer_id) orelse return false;
        return std.mem.eql(u8, @tagName(target.ready_state), expected);
    }

    fn ensureEngine(self: *@This()) !void {
        if (self.created) return;
        if (!engine.create(self.id, .{})) return error.EngineCreateFailed;
        self.created = true;
        installRecorder(self.id);
        Trace.reset();
    }

    fn destroyEngine(self: *@This()) void {
        if (!self.created) return;
        engine.destroy(self.id);
        self.created = false;
    }

    fn resetPath(self: *@This()) void {
        self.destroyEngine();
        Trace.reset();
        self.scheduled = false;
        self.target_timer_id = 0;
        self.pending_cancelled = false;
        self.cancel_task_enqueued = false;
        self.advances = 0;
        self.bad_cancel_delivery = false;
        self.bad_task_checkpoint = false;
        self.cancel_after_sibling_candidate = false;
    }

    fn rebuild(self: *@This()) !void {
        self.resetPath();
        const count = self.log_len;
        self.log_len = 0;
        for (self.log[0..count]) |act| {
            try self.apply(act);
            self.log[self.log_len] = act;
            self.log_len += 1;
        }
    }

    fn apply(self: *@This(), act: TimerCancelAct) !void {
        try self.ensureEngine();
        switch (act) {
            .schedule_timers => {
                const target_id = try helpers.evalInt(
                    self.id,
                    "globalThis.__stCancelTargetStarted=false; " ++
                        "globalThis.__stCancelSibling=setTimeout(()=>__stRecord__('A'),0); " ++
                        "globalThis.__stCancelTarget=setTimeout(()=>{__stCancelTargetStarted=true; __stRecord__('B');},0); " ++
                        "__stCancelTarget;",
                );
                self.target_timer_id = std.math.cast(i32, target_id) orelse return error.InvalidTargetTimerId;
                self.scheduled = true;
            },
            .cancel_pending => {
                if (!targetIsInReadyState(self, "none")) return error.TargetWasAlreadyReady;
                try helpers.evalOk(
                    self.id,
                    "if (!__stCancelTargetStarted) { clearTimeout(__stCancelTarget); __stRecord__('C'); } " ++
                        "else { clearTimeout(__stCancelTarget); __stRecord__('D'); }",
                );
                self.pending_cancelled = true;
                if (!hasTrace('B')) self.saw_pending_cancel = true;
            },
            .enqueue_cancel_task => {
                const after_sibling = hasTrace('A') and !hasTrace('B') and targetIsInReadyState(self, "firing");
                if (!engine.dispatchTask(
                    self.id,
                    "__stRecord__('X'); queueMicrotask(()=>{ " ++
                        "if (!__stCancelTargetStarted) { clearTimeout(__stCancelTarget); __stRecord__('C'); } " ++
                        "else { clearTimeout(__stCancelTarget); __stRecord__('D'); } __stRecord__('m'); });",
                )) return error.TaskRejected;
                self.cancel_task_enqueued = true;
                if (after_sibling) self.cancel_after_sibling_candidate = true;
            },
            .advance => {
                _ = engine.testing.advance(self.id, 0);
                self.advances += 1;
            },
        }
        self.observeTrace();
    }

    fn observeTrace(self: *@This()) void {
        var snapshot: [64]u8 = undefined;
        const trace = Trace.snapshot(&snapshot);
        var cancelled_before_start = false;
        var saw_a_before_cancel = false;
        var b_count: usize = 0;
        var a_count: usize = 0;
        var i: usize = 0;
        while (i < trace.len) : (i += 1) {
            switch (trace[i]) {
                'C' => {
                    cancelled_before_start = true;
                    if (self.cancel_after_sibling_candidate and saw_a_before_cancel) self.saw_cancel_after_sibling = true;
                },
                'B' => {
                    b_count += 1;
                    if (cancelled_before_start) self.bad_cancel_delivery = true;
                },
                'A' => {
                    a_count += 1;
                    saw_a_before_cancel = true;
                },
                'X' => {
                    if (i + 2 >= trace.len or (trace[i + 1] != 'C' and trace[i + 1] != 'D') or trace[i + 2] != 'm') self.bad_task_checkpoint = true;
                },
                else => {},
            }
        }
        if (a_count > 0) self.saw_sibling_delivery = true;
        if (a_count > 1 or b_count > 1) self.bad_cancel_delivery = true;
    }

    pub fn enabled(self: *@This()) []const TimerCancelAct {
        var count: usize = 0;
        if (!self.scheduled) {
            self.acts_buf[count] = .schedule_timers;
            count += 1;
        }
        if (self.scheduled and !self.pending_cancelled and self.advances == 0) {
            self.acts_buf[count] = .cancel_pending;
            count += 1;
        }
        if (self.scheduled and !self.cancel_task_enqueued and !hasTrace('B')) {
            self.acts_buf[count] = .enqueue_cancel_task;
            count += 1;
        }
        if (self.scheduled and self.advances < 3) {
            self.acts_buf[count] = .advance;
            count += 1;
        }
        return self.acts_buf[0..count];
    }

    pub fn step(self: *@This(), act: TimerCancelAct) !void {
        if (self.log_len == self.log.len) return error.LogFull;
        try self.apply(act);
        self.log[self.log_len] = act;
        self.log_len += 1;
    }

    pub fn undo(self: *@This(), _: TimerCancelAct) void {
        if (self.log_len == 0) return;
        self.log_len -= 1;
        self.rebuild() catch unreachable;
    }

    fn safetyOk(self: *@This()) !void {
        if (self.bad_cancel_delivery) return error.CancelledTimerDelivered;
        if (self.bad_task_checkpoint) return error.TaskCheckpointBroken;
        if (self.advances == 3 and hasTrace('C') and !hasTrace('A')) return error.SurvivingSiblingNotDelivered;
    }

    fn deinit(self: *@This()) void {
        self.destroyEngine();
    }
};

test "state_tcas engine: explores timer cancellation before and after a sibling task" {
    var world = TimerCancelWorld{ .id = helpers.nextInstanceId() };
    defer world.deinit();

    var safety = state_tcas.monitor.Safety(*TimerCancelWorld){
        .ctx = &world,
        .checkFn = TimerCancelWorld.safetyOk,
    };
    const Legal = struct {
        inner: *TimerCancelWorld,
        saf: *state_tcas.monitor.Safety(*TimerCancelWorld),
        pub fn enabled(self: *@This()) []const TimerCancelAct {
            return self.inner.enabled();
        }
        pub fn step(self: *@This(), act: TimerCancelAct) !void {
            try self.inner.step(act);
            try self.saf.observe();
        }
        pub fn undo(self: *@This(), act: TimerCancelAct) void {
            self.inner.undo(act);
        }
    };
    var legal = Legal{ .inner = &world, .saf = &safety };
    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(TimerCancelAct, &legal, 256, &stats);

    try testing.expect(stats.visits > 1);
    try testing.expect(stats.expansions > 0);
    try testing.expect(world.saw_pending_cancel);
    try testing.expect(world.saw_cancel_after_sibling);
    try testing.expect(world.saw_sibling_delivery);
}
