//! state_tcas over a real ActiveEngine + host dispatch / JS queues.
//!
//! Goes past bare Scheduler/Driver: creates an engine instance, queues real script tasks / native postTasks / Promise microtasks / setTimeout(0), and drives turns with `engine.testing.advance` (production TurnContext hooks).
//!
//! ## Process (live Engine — no fake BFS)
//! 1. **Explore shape**: act-log rebuild + `dfs` / `dfsKeyed` only. `undo` = destroyEngine + replay. Never claim `explore.bfs` over ActiveEngine/Driver.
//! 2. **L0/L1/L2 discipline**: explore dispatch = L0 `engine.testing.advance` / production turn path; pure clock = L1 `engine.testing.setNow` (strict); L2 Driver escape hatch is gap-only (`*_driver_gap.zig`). `ExploreAct` has no L2 variant. Never call `loop.dispatchEvents*` from explore.
//! 3. **Rebuild invariant**: act-log prefix → boot+apply observations match the live walk. Empty queues must not enable advance/checkpoint.
//! 4. **Key fields** (dfsKeyed): enqueue flags, advance_count, pending script queue, **Trace content** (fnv-fold of recorder bytes — not length alone), via `ExploreWorld.key`.
//! 5. **Out of explore (intentional)**: SyncWait begin↔end oscillation and beginExecution pairing stay on direct+Safety tests (see checklist below); do not add them to `ExploreAct` without a keyed depth-1 gate.
//!
//! Checklist (direct, not DFS): beginExecution host gate; SyncWait covered on Scheduler/Driver harnesses + gap Ungated probes.
//!
//! Cookbook: state_tcas tip 61ba72c / docs/harness.md (act-log-vs-bfs, testing helpers). Prefer catching jsbay contract bugs; do not "fix" production unless clear.
//!
//! Run: `zig build test-state-tcas-engine`. Also via `zig build test`.

const std = @import("std");
const testing = std.testing;
const state_tcas = @import("state_tcas");
const explore_adapters = @import("state_tcas_explore_adapters.zig");
const engine = @import("../engine.zig");
const dispatch = @import("../runtime/dispatch.zig");
const js_scheduler = @import("../runtime/js_scheduler.zig");
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const sync = @import("zev");

// ─── Shared JS-side recorder (native callback; does not drain microtasks) ────

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

    fn expect(expected: []const u8) !void {
        mutex.lock();
        defer mutex.unlock();
        try testing.expectEqualStrings(expected, bytes[0..len]);
    }

    fn snapshot(out: *[64]u8) []const u8 {
        mutex.lock();
        defer mutex.unlock();
        @memcpy(out[0..len], bytes[0..len]);
        return out[0..len];
    }

    fn currentLen() usize {
        mutex.lock();
        defer mutex.unlock();
        return len;
    }

    /// FNV-1a over recorder bytes — dfsKeyed must distinguish equal-length traces.
    fn fnv1a() u64 {
        mutex.lock();
        defer mutex.unlock();
        var h: u64 = 0xcbf29ce484222325;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            h ^= bytes[i];
            h *%= 0x100000001b3;
        }
        return h;
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

// ─── Contract probes (ActiveEngine path) ─────────────────────────────────────

test "state_tcas engine: script completion drains Promise before returning" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try helpers.evalOk(id, "Promise.resolve().then(() => __stRecord__('m'));");
            try Trace.expect("m");
        }
    }.run);
}

test "state_tcas engine: Promise microtask precedes setTimeout(0) macrotask" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try helpers.evalOk(id,
                \\__stRecord__('s');
                \\Promise.resolve().then(() => __stRecord__('m'));
                \\setTimeout(() => __stRecord__('t'), 0);
            );
            // Script boundary drained the microtask; timer still pending.
            try Trace.expect("sm");
            _ = engine.testing.advance(id, 0);
            try Trace.expect("smt");
        }
    }.run);
}

test "state_tcas engine: host tick runs one queued script then its microtasks" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try testing.expect(engine.dispatchTask(id, "__stRecord__('A'); queueMicrotask(() => __stRecord__('a'));"));
            try testing.expect(engine.dispatchTask(id, "__stRecord__('B'); queueMicrotask(() => __stRecord__('b'));"));

            _ = engine.testing.advance(id, 0);
            try Trace.expect("Aa");
            _ = engine.testing.advance(id, 0);
            try Trace.expect("AaBb");
        }
    }.run);
}

test "state_tcas engine: nested postTask waits for next tick (Safety)" {
    const Box = struct {
        first: usize = 0,
        second: usize = 0,
        nested_ran_same_tick: bool = false,
        fn safetyOk(ctx: *@This()) !void {
            if (ctx.nested_ran_same_tick) return error.SafetyViolation;
        }
    };
    const State = struct {
        id: i32,
        box: *Box,
        fn second(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.box.second += 1;
        }
        fn first(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.box.first += 1;
            std.debug.assert(dispatch.postTask(self.id, .{ .ctx = self, .run = second }));
            // Nested must not have run yet in this same tick.
            if (self.box.second != 0) self.box.nested_ran_same_tick = true;
        }
    };

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var box: Box = .{};
            var saf = state_tcas.monitor.Safety(*Box){ .ctx = &box, .checkFn = Box.safetyOk };
            var state = State{ .id = id, .box = &box };
            try testing.expect(dispatch.postTask(id, .{ .ctx = &state, .run = State.first }));
            try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
            try saf.observe();
            try testing.expectEqual(@as(usize, 1), box.first);
            try testing.expectEqual(@as(usize, 0), box.second);
            try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
            try testing.expectEqual(@as(usize, 1), box.second);
            try saf.observe();
        }
    }.run);
}

test "state_tcas engine: suspend blocks advance from delivering queued scripts" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try testing.expect(engine.dispatchTask(id, "__stRecord__('X');"));
            engine.suspendEventLoop(id);
            _ = engine.testing.advance(id, 0);
            try Trace.expect("");
            engine.resumeEventLoop(id);
            _ = engine.testing.advance(id, 0);
            try Trace.expect("X");
        }
    }.run);
}

test "state_tcas engine: allowsQueuedWork false under beginExecution (host gate)" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var ran: usize = 0;
            const Probe = struct {
                ran: *usize,
                fn bump(ctx: ?*anyopaque) void {
                    @as(*usize, @ptrCast(@alignCast(ctx.?))).* += 1;
                }
            };
            try testing.expect(dispatch.postTask(id, .{ .ctx = &ran, .run = Probe.bump }));

            var execution = js_scheduler.beginExecution(id) orelse return error.MissingScheduler;
            defer execution.end();
            try testing.expect(!js_scheduler.allowsQueuedWork(id));
            try testing.expectEqual(@as(usize, 0), dispatch.tickInstance(id));
            try testing.expectEqual(@as(usize, 0), ran);

            execution.end();
            try testing.expect(js_scheduler.allowsQueuedWork(id));
            try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
            try testing.expectEqual(@as(usize, 1), ran);
        }
    }.run);
}

// ─── exhaust.play stories over real queues ───────────────────────────────────

test "state_tcas engine: exhaust.play microtask-before-timer story" {
    const Act = enum { setup, advance };
    const Phase = enum { idle, promise_timer_queued, drained_mt };
    const Ctx = struct {
        id: i32,
        phase: Phase = .idle,
        allocator: std.mem.Allocator,
        fn phaseName(self: *const @This()) []const u8 {
            return switch (self.phase) {
                .idle => "idle",
                .promise_timer_queued => "promise_timer_queued",
                .drained_mt => "drained_mt",
            };
        }
        pub fn prepare(self: *@This()) !void {
            Trace.reset();
            installRecorder(self.id);
            self.phase = .idle;
        }
        pub fn step(self: *@This(), act: Act, pic: ?*state_tcas.Picture) !void {
            const before = self.phaseName();
            switch (act) {
                .setup => {
                    try helpers.evalOk(self.id,
                        \\Promise.resolve().then(() => __stRecord__('m'));
                        \\setTimeout(() => __stRecord__('t'), 0);
                    );
                    self.phase = .promise_timer_queued;
                },
                .advance => {
                    _ = engine.testing.advance(self.id, 0);
                    try Trace.expect("mt");
                    self.phase = .drained_mt;
                },
            }
            if (pic) |p| {
                const note: []const u8 = switch (act) {
                    .setup => "promise+setTimeout(0) queued",
                    .advance => "trace=mt",
                };
                try p.observe(self.allocator, .{
                    .before = before,
                    .after = self.phaseName(),
                    .label = @tagName(act),
                    .rejected = false,
                    .mutated = true,
                    .note = note,
                    .from = "Host",
                    .to = "Engine",
                });
            }
        }
        pub fn finish(_: *@This(), _: []const Act) !void {
            try Trace.expect("mt");
        }
        pub fn release(_: *@This()) void {}
    };

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var ctx: Ctx = .{ .id = id, .allocator = testing.allocator };
            try state_tcas.exhaust.play(Act, &ctx, &[_]Act{ .setup, .advance }, null);
        }
    }.run);
}

test "state_tcas engine: publish microtask-before-timer picture lock" {
    const Act = enum { setup, advance };
    const Phase = enum { idle, promise_timer_queued, drained_mt };
    const Ctx = struct {
        id: i32,
        phase: Phase = .idle,
        allocator: std.mem.Allocator,
        fn phaseName(self: *const @This()) []const u8 {
            return switch (self.phase) {
                .idle => "idle",
                .promise_timer_queued => "promise_timer_queued",
                .drained_mt => "drained_mt",
            };
        }
        pub fn prepare(self: *@This()) !void {
            Trace.reset();
            installRecorder(self.id);
            self.phase = .idle;
        }
        pub fn step(self: *@This(), act: Act, pic: ?*state_tcas.Picture) !void {
            const before = self.phaseName();
            switch (act) {
                .setup => {
                    try helpers.evalOk(self.id,
                        \\Promise.resolve().then(() => __stRecord__('m'));
                        \\setTimeout(() => __stRecord__('t'), 0);
                    );
                    self.phase = .promise_timer_queued;
                },
                .advance => {
                    _ = engine.testing.advance(self.id, 0);
                    try Trace.expect("mt");
                    self.phase = .drained_mt;
                },
            }
            if (pic) |p| {
                const note: []const u8 = switch (act) {
                    .setup => "promise+setTimeout(0) queued",
                    .advance => "trace=mt",
                };
                try p.observe(self.allocator, .{
                    .before = before,
                    .after = self.phaseName(),
                    .label = @tagName(act),
                    .rejected = false,
                    .mutated = true,
                    .note = note,
                    .from = "Host",
                    .to = "Engine",
                });
            }
        }
        pub fn finish(_: *@This(), _: []const Act) !void {
            try Trace.expect("mt");
        }
        pub fn release(_: *@This()) void {}
    };

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const allocator = testing.allocator;
            var ctx: Ctx = .{ .id = id, .allocator = allocator };
            var pic: state_tcas.Picture = .{};
            defer pic.deinit(allocator);
            try state_tcas.exhaust.play(Act, &ctx, &[_]Act{ .setup, .advance }, &pic);
            const text = try pic.render(
                allocator,
                "# Engine microtask before timer (state_tcas Observation)\n\n",
                "Host",
                "Engine",
            );
            defer allocator.free(text);
            try explore_adapters.lockNormalized(
                testing.io,
                allocator,
                "docs/state-tcas-engine-microtask-before-timer.md",
                text,
            );
            try testing.expect(std.mem.indexOf(u8, text, "sequenceDiagram") != null);
            try testing.expect(std.mem.indexOf(u8, text, "Host->>Engine: setup") != null);
            try testing.expect(std.mem.indexOf(u8, text, "promise_timer_queued") != null);
            try testing.expect(std.mem.indexOf(u8, text, "drained_mt") != null);
            try testing.expect(std.mem.indexOf(u8, text, "trace=mt") != null);
        }
    }.run);
}

test "state_tcas engine: exhaust.play two script tasks one-per-tick" {
    const Act = enum { enqueue_ab, tick1, tick2 };
    const Ctx = struct {
        id: i32,
        pub fn prepare(self: *@This()) !void {
            Trace.reset();
            installRecorder(self.id);
        }
        pub fn step(self: *@This(), act: Act, _: ?*state_tcas.picture.Picture) !void {
            switch (act) {
                .enqueue_ab => {
                    try testing.expect(engine.dispatchTask(self.id, "__stRecord__('A'); queueMicrotask(() => __stRecord__('a'));"));
                    try testing.expect(engine.dispatchTask(self.id, "__stRecord__('B'); queueMicrotask(() => __stRecord__('b'));"));
                },
                .tick1 => {
                    _ = engine.testing.advance(self.id, 0);
                    try Trace.expect("Aa");
                },
                .tick2 => {
                    _ = engine.testing.advance(self.id, 0);
                    try Trace.expect("AaBb");
                },
            }
        }
        pub fn finish(_: *@This(), _: []const Act) !void {}
        pub fn release(_: *@This()) void {}
    };

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var ctx: Ctx = .{ .id = id };
            try state_tcas.exhaust.play(Act, &ctx, &[_]Act{ .enqueue_ab, .tick1, .tick2 }, null);
        }
    }.run);
}

test "state_tcas engine: testing.setNow ClockRewind; clampNow absorbs; advance still clamps" {
    // Engine L1 mirrors Driver.testing. advance(i32,i64)i64 stays clamp host-tick.
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try engine.testing.setNow(id, 100);
            try testing.expectError(error.ClockRewind, engine.testing.setNow(id, 50));
            try engine.testing.setNow(id, 100); // same tick OK
            try engine.testing.clampNow(id, 50);
            // clampNow absorbed — clock still 100
            try engine.testing.setNow(id, 100);
            try engine.testing.clampNow(id, 120);
            try engine.testing.setNow(id, 120);
            // advance remains clamp (stale host): smaller now_ms must not Rewind
            _ = engine.testing.advance(id, 50);
            try testing.expectError(error.InvalidArgument, engine.testing.setNow(id, -1));
            try testing.expectError(error.InvalidArgument, engine.testing.clampNow(id, -1));
        }
    }.run);
}

// ─── DFS explore with act-log rebuild (engine opaque → no BFS) ───────────────

/// Explore acts: enqueue + L0 `advance` only. No L2 escape; clock acts use `engine.testing.setNow` outside this enum when needed.
const ExploreAct = enum {
    enqueue_a,
    enqueue_b,
    enqueue_timer,
    advance,
};

const PendingScript = enum(u2) { none = 0, a = 1, b = 2 };

/// Live engine. Undo destroys the instance and replays the act log — honest because ActiveEngine / Driver / queues cannot be value-copied for BFS. Enabled set is finite: each enqueue once, at most `max_advances` advances.
const ExploreWorld = struct {
    id: i32,
    created: bool = false,
    log: [32]ExploreAct = undefined,
    log_len: usize = 0,
    enabled_buf: [4]ExploreAct = undefined,

    enqueued_a: bool = false,
    enqueued_b: bool = false,
    enqueued_timer: bool = false,
    pending_queue: [2]PendingScript = .{ .none, .none },
    pending_len: u8 = 0,
    advance_count: usize = 0,
    max_advances: usize = 3,

    /// Sticky across undo/rebuild: work was ever enqueued this run (Liveness). Not cleared by `rebuild` — seed `enabledFn` must not vacuum `finish`.
    ever_enqueued: bool = false,

    /// Safety: macrotask letter appeared between a task and its microtask pair.
    bad_order: bool = false,
    /// Liveness helper: saw delivery after queuing work.
    delivered: bool = false,

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

    /// Replay `log[0..n]` after destroy. Only enabled-legal acts appear in the log (step only appends after apply); rebuild must stay infallible for those prefixes — OOM/`EngineCreateFailed` is the only unexpected path, hence `undo` uses `catch unreachable` (package undo is void).
    fn rebuild(self: *@This()) !void {
        self.destroyEngine();
        Trace.reset();
        self.enqueued_a = false;
        self.enqueued_b = false;
        self.enqueued_timer = false;
        self.pending_queue = .{ .none, .none };
        self.pending_len = 0;
        self.advance_count = 0;
        self.bad_order = false;
        self.delivered = false;
        // ever_enqueued sticky — do not clear.
        const n = self.log_len;
        self.log_len = 0;
        if (n == 0) return;
        try self.ensureEngine();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.apply(self.log[i]);
            self.log[self.log_len] = self.log[i];
            self.log_len += 1;
        }
    }

    fn apply(self: *@This(), act: ExploreAct) !void {
        try self.ensureEngine();
        const before = Trace.currentLen();
        switch (act) {
            .enqueue_a => {
                if (self.enqueued_a) return;
                try testing.expect(engine.dispatchTask(self.id, "__stRecord__('A'); queueMicrotask(() => __stRecord__('a'));"));
                self.enqueued_a = true;
                self.ever_enqueued = true;
                self.pending_queue[self.pending_len] = .a;
                self.pending_len += 1;
            },
            .enqueue_b => {
                if (self.enqueued_b) return;
                try testing.expect(engine.dispatchTask(self.id, "__stRecord__('B'); queueMicrotask(() => __stRecord__('b'));"));
                self.enqueued_b = true;
                self.ever_enqueued = true;
                self.pending_queue[self.pending_len] = .b;
                self.pending_len += 1;
            },
            .enqueue_timer => {
                if (self.enqueued_timer) return;
                try helpers.evalOk(self.id, "setTimeout(() => __stRecord__('T'), 0);");
                self.enqueued_timer = true;
                self.ever_enqueued = true;
            },
            .advance => {
                _ = engine.testing.advance(self.id, 0);
                self.advance_count += 1;
            },
        }
        const after = Trace.currentLen();
        if (after > before) self.delivered = true;
        var snap: [64]u8 = undefined;
        const tr = Trace.snapshot(&snap);
        if (brokenTaskMicroPairs(tr)) self.bad_order = true;
        if (act == .advance and self.pending_len > 0 and after > before) {
            for (tr[before..after]) |c| {
                if (c == 'A' and self.pending_queue[0] == .a) {
                    self.pending_queue[0] = self.pending_queue[1];
                    self.pending_queue[1] = .none;
                    self.pending_len -= 1;
                    break;
                } else if (c == 'B' and self.pending_queue[0] == .b) {
                    self.pending_queue[0] = self.pending_queue[1];
                    self.pending_queue[1] = .none;
                    self.pending_len -= 1;
                    break;
                }
            }
        }
    }

    pub fn enabled(self: *@This()) []const ExploreAct {
        var n: usize = 0;
        if (!self.enqueued_a) {
            self.enabled_buf[n] = .enqueue_a;
            n += 1;
        }
        if (!self.enqueued_b) {
            self.enabled_buf[n] = .enqueue_b;
            n += 1;
        }
        if (!self.enqueued_timer) {
            self.enabled_buf[n] = .enqueue_timer;
            n += 1;
        }
        // Empty-work gate (harness.md): do not enable advance/checkpoint with nothing pending.
        if (self.advance_count < self.max_advances and
            (self.enqueued_a or self.enqueued_b or self.enqueued_timer))
        {
            self.enabled_buf[n] = .advance;
            n += 1;
        }
        return self.enabled_buf[0..n];
    }

    pub fn step(self: *@This(), act: ExploreAct) !void {
        if (self.log_len >= self.log.len) return error.LogFull;
        try self.apply(act);
        self.log[self.log_len] = act;
        self.log_len += 1;
    }

    pub fn undo(self: *@This(), _: ExploreAct) void {
        if (self.log_len == 0) return;
        self.log_len -= 1;
        self.rebuild() catch unreachable;
    }

    pub fn key(self: *const @This()) u64 {
        // State-keyed for dfsKeyed: enqueue flags + advance_count decide enabled(); pending script queue tracks FIFO delivery order; Trace length+content distinguish equal-length delivery orders ("Aa" vs "Bb").
        //
        // Monitor sticky bits (ever_enqueued / delivered / bad_order) are not keyed: bad_order fails Safety on observe; delivered/ever_enqueued are finish helpers recomputed or sticky outside prune.
        var k: u64 = 0;
        if (self.enqueued_a) k |= 1;
        if (self.enqueued_b) k |= 2;
        if (self.enqueued_timer) k |= 4;
        k |= @as(u64, @intCast(self.advance_count)) << 3;
        k |= @as(u64, @intCast(Trace.currentLen() & 0x3f)) << 8;
        k |= @as(u64, @backingInt(self.pending_queue[0])) << 14;
        k |= @as(u64, @backingInt(self.pending_queue[1])) << 16;
        k ^= Trace.fnv1a() << 18;
        return k;
    }

    fn deinit(self: *@This()) void {
        self.destroyEngine();
    }

    fn safetyOk(ctx: *@This()) !void {
        if (ctx.bad_order) return error.SafetyViolation;
    }

    fn isEnabled(ctx: *@This()) bool {
        // Sticky: seed after DFS undo is idle, but work was offered this run. Using only live enqueue flags makes finish-after-undo a no-op.
        return ctx.ever_enqueued;
    }

    fn isGoal(ctx: *@This()) bool {
        return ctx.delivered;
    }
};

fn brokenTaskMicroPairs(tr: []const u8) bool {
    // Between a task letter and its microtask, no other macrotask (A/B/T) may appear.
    const pairs = [_]struct { u8, u8 }{ .{ 'A', 'a' }, .{ 'B', 'b' } };
    for (pairs) |pair| {
        const task = pair[0];
        const micro = pair[1];
        var i: usize = 0;
        while (i < tr.len) : (i += 1) {
            if (tr[i] != task) continue;
            var j = i + 1;
            while (j < tr.len) : (j += 1) {
                if (tr[j] == micro) break;
                if (tr[j] == 'A' or tr[j] == 'B' or tr[j] == 'T') return true;
            }
        }
    }
    return false;
}

test "state_tcas engine: DFS explore host queues with Safety+Liveness" {
    const id = helpers.nextInstanceId();
    var world = ExploreWorld{ .id = id };
    defer world.deinit();

    var saf = state_tcas.monitor.Safety(*ExploreWorld){
        .ctx = &world,
        .checkFn = ExploreWorld.safetyOk,
    };
    var liv = state_tcas.monitor.Liveness(*ExploreWorld){
        .ctx = &world,
        .enabledFn = ExploreWorld.isEnabled,
        .goalFn = ExploreWorld.isGoal,
    };

    var legal: explore_adapters.Monitored(ExploreAct, ExploreWorld) = .{ .inner = &world, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    try state_tcas.explore.dfs(ExploreAct, &legal, 512, &stats);
    try liv.finish();
    // Explicit: sticky enabledFn alone is not enough — goal must have been noted.
    try testing.expect(liv.reached);
    try testing.expect(stats.visits > 0);
}

test "state_tcas engine: dfsKeyed prunes on logical queue key" {
    const id = helpers.nextInstanceId();
    var world = ExploreWorld{ .id = id };
    defer world.deinit();

    var saf = state_tcas.monitor.Safety(*ExploreWorld){
        .ctx = &world,
        .checkFn = ExploreWorld.safetyOk,
    };
    var liv = state_tcas.monitor.Liveness(*ExploreWorld){
        .ctx = &world,
        .enabledFn = ExploreWorld.isEnabled,
        .goalFn = ExploreWorld.isGoal,
    };

    var keyed: explore_adapters.MonitoredKeyed(ExploreAct, ExploreWorld) = .{ .inner = &world, .saf = &saf, .liv = &liv };
    var stats: state_tcas.explore.Stats = .{};
    var visited = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer visited.deinit();
    try state_tcas.explore.dfsKeyed(ExploreAct, u64, &keyed, 512, &stats, &visited);
    try liv.finish();
    try testing.expect(liv.reached);
    try testing.expect(stats.visits >= 2);
}

test "state_tcas engine: dfsKeyed key distinguishes equal-length Trace orders" {
    // "Aa" vs "Bb" (equal Trace length) must not share a key.
    var key_a: u64 = undefined;
    var key_b: u64 = undefined;
    var len_a: usize = undefined;
    var len_b: usize = undefined;
    {
        var world = ExploreWorld{ .id = helpers.nextInstanceId() };
        defer world.deinit();
        try world.step(.enqueue_a);
        try world.step(.advance);
        var snap: [64]u8 = undefined;
        const tr = Trace.snapshot(&snap);
        try testing.expectEqualStrings("Aa", tr);
        key_a = world.key();
        len_a = tr.len;
    }
    {
        var world = ExploreWorld{ .id = helpers.nextInstanceId() };
        defer world.deinit();
        try world.step(.enqueue_b);
        try world.step(.advance);
        var snap: [64]u8 = undefined;
        const tr = Trace.snapshot(&snap);
        try testing.expectEqualStrings("Bb", tr);
        key_b = world.key();
        len_b = tr.len;
    }
    try testing.expectEqual(len_a, len_b);
    try testing.expect(key_a != key_b);
}

test "state_tcas engine: rebuild of every act-log prefix succeeds" {
    const id = helpers.nextInstanceId();
    var world = ExploreWorld{ .id = id };
    defer world.deinit();
    const script = [_]ExploreAct{ .enqueue_a, .enqueue_timer, .advance, .enqueue_b, .advance };
    for (script) |act| {
        try world.step(act);
    }
    const full = world.log_len;
    var prefix: usize = 0;
    while (prefix <= full) : (prefix += 1) {
        world.log_len = prefix;
        try world.rebuild();
        try testing.expectEqual(prefix, world.log_len);
    }
}

test "state_tcas engine: BFS clone of ActiveEngine intentionally unsupported" {
    // Document hard stop for value-copy explore over a live engine.
    const EngineInstance = @TypeOf(engine);
    _ = EngineInstance;
    // No clone API on the public engine surface for snapshotting VM+queues.
    try testing.expect(!@hasDecl(engine, "clone"));
}

test "state_tcas engine: dfsKeyed key distinguishes pending script order before drain" {
    // Before any advance, Trace is empty, but pending script order determines future delivery order, so distinct FIFO enqueue orders must produce distinct keys.
    var wa = ExploreWorld{ .id = helpers.nextInstanceId() };
    defer wa.deinit();
    var wb = ExploreWorld{ .id = helpers.nextInstanceId() };
    defer wb.deinit();
    try wa.step(.enqueue_a);
    try wa.step(.enqueue_b);
    try wb.step(.enqueue_b);
    try wb.step(.enqueue_a);
    try testing.expect(wa.key() != wb.key());
    try testing.expectEqual(wa.enabled().len, wb.enabled().len);
}

test "state_tcas engine: rebuild cost split create vs replay" {
    // Interleave destroy+create vs full rebuild samples so cache effects hit both arms similarly. replay_est = full - destroy_create when positive.
    const rounds: usize = 16;
    var world = ExploreWorld{ .id = helpers.nextInstanceId() };
    defer world.deinit();
    const script = [_]ExploreAct{ .enqueue_a, .enqueue_b, .enqueue_timer, .advance, .advance };
    for (script) |act| {
        try world.step(act);
    }
    const log_len = world.log_len;
    try world.rebuild();

    var boot_ns: u64 = 0;
    var full_ns: u64 = 0;
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        var t0 = explore_adapters.monoNs();
        world.destroyEngine();
        try world.ensureEngine();
        boot_ns += explore_adapters.monoNs() - t0;

        t0 = explore_adapters.monoNs();
        try world.rebuild();
        full_ns += explore_adapters.monoNs() - t0;
    }
    const avg_boot = boot_ns / rounds;
    const avg_full = full_ns / rounds;
    const replay_est: u64 = if (avg_full > avg_boot) avg_full - avg_boot else 0;
    std.debug.print(
        "state_tcas engine rebuild cost: destroy_create_ns_avg={d} full_rebuild_ns_avg={d} replay_est_ns_avg={d} rounds={d} log_len={d}\n",
        .{ avg_boot, avg_full, replay_est, rounds, log_len },
    );
    try testing.expect(avg_boot > 0);
    try testing.expect(avg_full > 0);
    try testing.expectEqual(script.len, log_len);
}
