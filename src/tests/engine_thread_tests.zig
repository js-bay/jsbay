//! Engine-thread regression tests cover the internal queue, waiters, reentrancy, stop/restart and teardown rules. The engine-thread mechanism remains private to the runtime and inspector implementation.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const c_api = @import("../c_api.zig");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const host_value = @import("../abi/host_value.zig");
const helpers = @import("test_helpers.zig");
const io = @import("../platform/io.zig");
const weakcb = @import("../value/weakcb.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const ActiveEngine = backend.ActiveEngine;

const jsbay_ok: c_int = 0;
const jsbay_timeout: c_int = 1;
const jsbay_destroyed: c_int = 2;
const jsbay_exception: c_int = 3;
const jsbay_invalid: c_int = 4;

const host_undefined: u32 = 0;
const host_number: u32 = 1;
const host_string: u32 = 2;

const JsBayHostValue = host_value.HostValue;
const JsBayHostFn = host_value.HostFn;
const testThreadId = c_api.test_only.threadId;
const testThreadPost = c_api.test_only.threadPost;
const testThreadWait = c_api.test_only.threadWait;
const testThreadBarrier = c_api.test_only.threadBarrier;
const testThreadRun = c_api.test_only.threadRun;
const testThreadEvalCString = c_api.test_only.threadEvalCString;

const posted_name = "<posted>";

fn thisThreadId() u64 {
    return @as(u64, std.Thread.getCurrentId());
}

fn processIdForPath() u64 {
    if (comptime builtin.os.tag == .windows) {
        const Windows = struct {
            extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
        };
        return Windows.GetCurrentProcessId();
    }
    return @intCast(std.c.getpid());
}

fn clearHost(out: *JsBayHostValue) void {
    out.* = .{
        .tag = host_undefined,
        .reserved = 0,
        .number = 0,
        .ptr = null,
        .len = 0,
    };
}

fn spinUntil(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const start = io.monotonicMilliseconds();
    while (!flag.load(.seq_cst)) {
        if (io.monotonicMilliseconds() - start >= timeout_ms) return false;
        io.sleepMs(1);
    }
    return true;
}

fn spinUntilEq(flag: *const std.atomic.Value(u32), expected: u32, timeout_ms: i64) bool {
    const start = io.monotonicMilliseconds();
    while (flag.load(.seq_cst) != expected) {
        if (io.monotonicMilliseconds() - start >= timeout_ms) return false;
        io.sleepMs(1);
    }
    return true;
}

/// Join a thread that is supposed to finish. If it does not, the process exits: joining would hang the suite, and so would returning while the thread stays blocked.
fn joinOrExit(thread: std.Thread, done: *const std.atomic.Value(bool), timeout_ms: i64, what: []const u8) void {
    if (!spinUntil(done, timeout_ms)) {
        std.debug.print("{s} did not finish within {d}ms\n", .{ what, timeout_ms });
        std.process.exit(1);
    }
    thread.join();
}

const Copied = struct {
    present: bool,
    len: usize,
};

fn takeCString(src: ?[*:0]u8, buf: []u8) Copied {
    const ptr = src orelse return .{ .present = false, .len = 0 };
    const text = std.mem.span(ptr);
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    c_api.test_only.freeCString(src);
    return .{ .present = true, .len = n };
}

fn expectCopied(copied: Copied, buf: []const u8, expected: []const u8) !void {
    try testing.expect(copied.present);
    try testing.expectEqualStrings(expected, buf[0..copied.len]);
}

const Live = struct {
    id: i32,
    release: ?*std.atomic.Value(bool) = null,
    started: bool = false,
    closed: bool = false,

    fn close(self: *Live) void {
        if (self.closed) return;
        if (self.release) |flag| flag.store(true, .seq_cst);
        if (self.started) engine_thread_mod.threadStop(self.id);
        engine.destroy(self.id);
        self.closed = true;
    }
};

fn createInstance(id: i32) !Live {
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    return .{ .id = id };
}

fn install(id: i32, name: []const u8, func: JsBayHostFn, user: ?*anyopaque) !void {
    try testing.expect(engine_thread_mod.hostInstall(id, name, func, user));
}

fn startThread(live: *Live) !void {
    try testing.expect(engine_thread_mod.threadStart(live.id));
    live.started = true;
}

// ---------------------------------------------------------------------------
// Host callbacks. user_data is the test's stack state.
// ---------------------------------------------------------------------------

const ThreadProbe = struct {
    seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *ThreadProbe = @ptrCast(@alignCast(user.?));
        self.seen.store(thisThreadId(), .seq_cst);
        clearHost(out);
        return 0;
    }
};

const EnteredProbe = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *EnteredProbe = @ptrCast(@alignCast(user.?));
        self.entered.store(true, .seq_cst);
        clearHost(out);
        return 0;
    }
};

const AddProbe = struct {
    seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        argc: u32,
        argv: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *AddProbe = @ptrCast(@alignCast(user.?));
        self.seen.store(thisThreadId(), .seq_cst);
        var sum: f64 = 0;
        var i: u32 = 0;
        while (i < argc) : (i += 1) {
            const arg = argv.?[i];
            if (arg.tag != host_number) {
                clearHost(out);
                return 1;
            }
            sum += arg.number;
        }
        out.* = .{
            .tag = host_number,
            .reserved = 0,
            .number = sum,
            .ptr = null,
            .len = 0,
        };
        return 0;
    }
};

const StringArgsProbe = struct {
    valid: bool = true,
    calls: usize = 0,

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        argc: u32,
        argv: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *StringArgsProbe = @ptrCast(@alignCast(user.?));
        self.calls += 1;
        const expected = [_][]const u8{ "alpha", "你好", "", "x\x00y" };
        if (argc != expected.len or argv == null) {
            self.valid = false;
        } else {
            for (expected, 0..) |want, i| {
                const got = argv.?[i];
                if (got.tag != host_string or got.len != want.len) {
                    self.valid = false;
                    continue;
                }
                if (want.len == 0) {
                    if (got.ptr != null) self.valid = false;
                } else if (got.ptr == null or !std.mem.eql(u8, got.ptr.?[0..got.len], want)) {
                    self.valid = false;
                }
            }
        }
        const result = "ok";
        out.* = .{
            .tag = host_string,
            .reserved = 0,
            .number = 0,
            .ptr = result.ptr,
            .len = result.len,
        };
        return 0;
    }
};

const ManyStringArgsProbe = struct {
    valid: bool = true,
    calls: usize = 0,

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        argc: u32,
        argv: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *ManyStringArgsProbe = @ptrCast(@alignCast(user.?));
        self.calls += 1;
        const expected = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg", "hhhhhhhh", "iiiiiiiii" };
        if (argc != expected.len or argv == null) {
            self.valid = false;
        } else {
            for (expected, 0..) |want, i| {
                const got = argv.?[i];
                if (got.tag != host_string or got.ptr == null or got.len != want.len or
                    !std.mem.eql(u8, got.ptr.?[0..got.len], want))
                {
                    self.valid = false;
                }
            }
        }
        clearHost(out);
        return 0;
    }
};

fn echoCb(
    _: c_int,
    _: ?*anyopaque,
    _: u32,
    _: ?[*]const JsBayHostValue,
    out: *JsBayHostValue,
) callconv(.c) c_int {
    const text = "pong";
    out.* = .{
        .tag = host_string,
        .reserved = 0,
        .number = 0,
        .ptr = text.ptr,
        .len = text.len,
    };
    return 0;
}

const NopProbe = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    elapsed_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *NopProbe = @ptrCast(@alignCast(user.?));
        const started = io.monotonicMilliseconds();
        // No cross-thread post/wait here. Returning no payload is the contract.
        clearHost(out);
        const elapsed = io.monotonicMilliseconds() - started;
        self.elapsed_ms.store(@intCast(elapsed), .seq_cst);
        self.entered.store(true, .seq_cst);
        return 0;
    }
};

const Hold = struct {
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cap_ms: i64,

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *Hold = @ptrCast(@alignCast(user.?));
        self.entered.store(true, .seq_cst);
        const started = io.monotonicMilliseconds();
        while (!self.release.load(.seq_cst)) {
            if (io.monotonicMilliseconds() - started >= self.cap_ms) break;
            io.sleepMs(1);
        }
        self.finished.store(true, .seq_cst);
        clearHost(out);
        return 0;
    }
};

const Order = struct {
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 0 idle, 1 inside the first script, 2 the first script's callback has returned.
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    second_entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    second_observed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    overlap: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cap_ms: i64,

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        argc: u32,
        argv: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *Order = @ptrCast(@alignCast(user.?));
        clearHost(out);
        if (argc < 1 or argv.?[0].tag != host_number) return 1;
        const which: i32 = @intFromFloat(argv.?[0].number);
        if (which == 1) {
            self.counter.store(1, .seq_cst);
            const started = io.monotonicMilliseconds();
            while (!self.release.load(.seq_cst)) {
                if (self.second_entered.load(.seq_cst)) self.overlap.store(true, .seq_cst);
                if (io.monotonicMilliseconds() - started >= self.cap_ms) break;
                io.sleepMs(1);
            }
            self.counter.store(2, .seq_cst);
            return 0;
        }
        if (which == 2) {
            self.second_observed.store(self.counter.load(.seq_cst), .seq_cst);
            self.second_entered.store(true, .seq_cst);
            return 0;
        }
        return 1;
    }
};

const Reentry = struct {
    ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    on_engine_thread: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    nested_status: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),
    result: [32]u8 = undefined,
    result_len: usize = 0,

    fn cb(
        instance_id: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *Reentry = @ptrCast(@alignCast(user.?));
        const engine_thread = testThreadId(instance_id);
        self.on_engine_thread.store(engine_thread != 0 and engine_thread == thisThreadId(), .seq_cst);

        const nested_src = "40+2";
        const nested_name = "nested.js";
        const job = testThreadPost(
            instance_id,
            nested_src.ptr,
            nested_src.len,
            nested_name.ptr,
            nested_name.len,
        );
        var result: ?[*:0]u8 = null;
        var err: ?[*:0]u8 = null;
        const status = if (job == 0)
            jsbay_invalid
        else
            testThreadWait(instance_id, job, 800, &result, &err);
        self.nested_status.store(status, .seq_cst);
        const copied = takeCString(result, &self.result);
        self.result_len = copied.len;
        c_api.test_only.freeCString(err);
        const matched = status == jsbay_ok and copied.present and std.mem.eql(u8, self.result[0..copied.len], "42");
        self.ok.store(matched, .seq_cst);

        out.* = .{
            .tag = host_number,
            .reserved = 0,
            .number = 1,
            .ptr = null,
            .len = 0,
        };
        return 0;
    }
};

const RunJob = struct {
    id: i32,
    src: []const u8,
    filename: []const u8,
    timeout_ms: u64,
    status: c_int = -1,
    result_buf: [128]u8 = undefined,
    result: Copied = .{ .present = false, .len = 0 },
    err_buf: [256]u8 = undefined,
    err: Copied = .{ .present = false, .len = 0 },
    caller_thread: u64 = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn go(self: *RunJob) void {
        self.caller_thread = thisThreadId();
        var result: ?[*:0]u8 = null;
        var err: ?[*:0]u8 = null;
        self.status = testThreadRun(
            self.id,
            self.src.ptr,
            self.src.len,
            self.filename.ptr,
            self.filename.len,
            self.timeout_ms,
            &result,
            &err,
        );
        self.result = takeCString(result, &self.result_buf);
        self.err = takeCString(err, &self.err_buf);
        self.done.store(true, .seq_cst);
    }
};

const Poster = struct {
    id: i32,
    src: []const u8,
    job: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn go(self: *Poster) void {
        const job = testThreadPost(
            self.id,
            self.src.ptr,
            self.src.len,
            posted_name.ptr,
            posted_name.len,
        );
        self.job.store(job, .seq_cst);
        self.returned.store(true, .seq_cst);
    }
};

const Waiter = struct {
    id: i32,
    job: u64,
    timeout_ms: u64,
    status: c_int = -1,
    elapsed_ms: i64 = 0,
    calling: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn go(self: *Waiter) void {
        self.calling.store(true, .seq_cst);
        const started = io.monotonicMilliseconds();
        var result: ?[*:0]u8 = null;
        var err: ?[*:0]u8 = null;
        self.status = testThreadWait(self.id, self.job, self.timeout_ms, &result, &err);
        self.elapsed_ms = io.monotonicMilliseconds() - started;
        c_api.test_only.freeCString(result);
        c_api.test_only.freeCString(err);
        self.done.store(true, .seq_cst);
    }
};

const BarrierWait = struct {
    id: i32,
    timeout_ms: u64,
    status: c_int = -1,
    calling: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn go(self: *BarrierWait) void {
        self.calling.store(true, .seq_cst);
        self.status = testThreadBarrier(self.id, self.timeout_ms);
        self.done.store(true, .seq_cst);
    }
};

fn runOnWorker(job: *RunJob) !void {
    const worker = try std.Thread.spawn(.{}, RunJob.go, .{job});
    joinOrExit(worker, &job.done, 3000, "testThreadRun");
}

// ---------------------------------------------------------------------------
// 1. Posted work runs on the engine thread, and waiting observes completion.
// ---------------------------------------------------------------------------

fn skipSpikeUnlessGreen() !void {
    // No-op placeholder (Hermes green). Escargot: after-stop / nested / filename peeled;
    // destroy-defer / unstarted use skipEscargotDestroyDefer (bdwgc ABRT).
    _ = {};
}

/// Escargot: destroy-from-host during direct eval still ABRTs in bdwgc (not cheap).
fn skipEscargotDestroyDefer() !void {
    if (comptime backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
}

/// Mid-script interrupt (infinite while): Hermes stop/destroy → asyncTriggerTimeout; Escargot none.
fn skipSpikeNeedsNativeInterrupt() !void {
    if (comptime backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
}

/// Escargot hostInstall + stop/destroy/dispatch still SEGV (GC) in this pin; Hermes is green.
fn skipEscargotEtHost() !void {
    if (comptime backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
}

test "engine thread: a script posted from another thread runs there, and wait sees its result" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    var probe = ThreadProbe{};
    try install(id, "hostRecord", ThreadProbe.cb, &probe);
    try startThread(&live);

    // Length stops before the throw. A C-string read of this buffer throws.
    const storage = "hostRecord(), 7; throw new Error(\"past-len\")";
    const src = storage[0.."hostRecord(), 7".len];
    var job = RunJob{
        .id = id,
        .src = src,
        .filename = "<engine-thread>",
        .timeout_ms = 2000,
    };
    try runOnWorker(&job);

    if (job.status != jsbay_ok) {
        std.debug.print("engine run status={d} err={s}\n", .{
            job.status,
            job.err_buf[0..job.err.len],
        });
    }
    try testing.expectEqual(jsbay_ok, job.status);
    try expectCopied(job.result, &job.result_buf, "7");

    const engine_thread = testThreadId(id);
    const seen = probe.seen.load(.seq_cst);
    try testing.expect(engine_thread != 0);
    try testing.expect(seen != 0);
    try testing.expectEqual(engine_thread, seen);
    try testing.expect(seen != job.caller_thread);
}

test "engine thread: waiting consumes a settled job result" {
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    try startThread(&live);

    const job = testThreadPost(id, "40 + 2", 6, posted_name.ptr, posted_name.len);
    try testing.expect(job != 0);
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    try testing.expectEqual(jsbay_ok, testThreadWait(id, job, 2000, &result, &err));
    var result_buf: [16]u8 = undefined;
    const copied = takeCString(result, &result_buf);
    try expectCopied(copied, &result_buf, "42");
    try testing.expectEqual(jsbay_invalid, testThreadWait(id, job, 0, &result, &err));
}

test "engine thread: post returns while that script is still running; wait completes only after it" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var hold = Hold{ .cap_ms = 3000 };
    live.release = &hold.release;
    defer live.close();

    try install(id, "hostHold", Hold.cb, &hold);
    try startThread(&live);

    var poster = Poster{ .id = id, .src = "hostHold()" };
    const poster_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&hold.entered, 1000) or !spinUntil(&poster.returned, 1000)) {
        std.debug.print("post did not return while hostHold was still inside the callback\n", .{});
        std.process.exit(1);
    }
    poster_thread.join();
    try testing.expect(!hold.finished.load(.seq_cst));
    const job = poster.job.load(.seq_cst);
    try testing.expect(job != 0);

    var waiter = Waiter{ .id = id, .job = job, .timeout_ms = 2000 };
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.go, .{&waiter});
    if (!spinUntil(&waiter.calling, 1000)) {
        std.debug.print("waiter did not enter testThreadWait\n", .{});
        std.process.exit(1);
    }
    try testing.expect(!waiter.done.load(.seq_cst));
    try testing.expect(!hold.finished.load(.seq_cst));

    hold.release.store(true, .seq_cst);
    joinOrExit(waiter_thread, &waiter.done, 2000, "testThreadWait after release");
    try testing.expect(hold.finished.load(.seq_cst));
    try testing.expectEqual(jsbay_ok, waiter.status);
}

test "engine thread: the second posted script does not start until the first returns" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var order = Order{ .cap_ms = 3000 };
    live.release = &order.release;
    defer live.close();

    try install(id, "hostOrder", Order.cb, &order);
    try startThread(&live);

    var first = Poster{ .id = id, .src = "hostOrder(1)" };
    var second = Poster{ .id = id, .src = "hostOrder(2)" };
    // Queue the first script and wait until its callback is holding. Posting the second at the same time can put hostOrder(2) ahead of hostOrder(1).
    const t1 = try std.Thread.spawn(.{}, Poster.go, .{&first});
    if (!spinUntil(&first.returned, 1000) or !spinUntilEq(&order.counter, 1, 1000)) {
        std.debug.print("ordered posts did not reach the first callback\n", .{});
        std.process.exit(1);
    }
    t1.join();
    const t2 = try std.Thread.spawn(.{}, Poster.go, .{&second});
    if (!spinUntil(&second.returned, 1000)) {
        std.debug.print("second post did not return while the first callback was holding\n", .{});
        std.process.exit(1);
    }
    t2.join();

    // First script is still inside its callback. The second must not have entered.
    try testing.expect(!order.second_entered.load(.seq_cst));
    try testing.expect(!order.overlap.load(.seq_cst));

    order.release.store(true, .seq_cst);
    try testing.expect(spinUntilEq(&order.counter, 2, 2000));
    try testing.expect(spinUntil(&order.second_entered, 2000));
    try testing.expectEqual(@as(u32, 2), order.second_observed.load(.seq_cst));
    try testing.expect(!order.overlap.load(.seq_cst));
}

test "engine thread: a barrier posted after those scripts waits until both have run" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var order = Order{ .cap_ms = 3000 };
    live.release = &order.release;
    defer live.close();

    try install(id, "hostOrder", Order.cb, &order);
    try startThread(&live);

    var first = Poster{ .id = id, .src = "hostOrder(1)" };
    var second = Poster{ .id = id, .src = "hostOrder(2)" };
    const t1 = try std.Thread.spawn(.{}, Poster.go, .{&first});
    if (!spinUntil(&first.returned, 1000) or !spinUntilEq(&order.counter, 1, 1000)) {
        std.debug.print("barrier setup: first callback was not holding\n", .{});
        std.process.exit(1);
    }
    t1.join();
    const t2 = try std.Thread.spawn(.{}, Poster.go, .{&second});
    if (!spinUntil(&second.returned, 1000)) {
        std.debug.print("barrier setup: second post did not return\n", .{});
        std.process.exit(1);
    }
    t2.join();

    var barrier = BarrierWait{ .id = id, .timeout_ms = 2000 };
    const barrier_thread = try std.Thread.spawn(.{}, BarrierWait.go, .{&barrier});
    if (!spinUntilEq(&order.counter, 1, 1000) or !spinUntil(&barrier.calling, 1000)) {
        std.debug.print("barrier did not start while the first script was still running\n", .{});
        std.process.exit(1);
    }
    // Both scripts were posted before the barrier. It must still be blocked while the first callback has not returned and the second has not run.
    try testing.expect(!barrier.done.load(.seq_cst));
    try testing.expect(!order.second_entered.load(.seq_cst));

    order.release.store(true, .seq_cst);
    joinOrExit(barrier_thread, &barrier.done, 2000, "testThreadBarrier");
    try testing.expectEqual(jsbay_ok, barrier.status);
    try testing.expect(order.second_entered.load(.seq_cst));
    try testing.expectEqual(@as(u32, 2), order.counter.load(.seq_cst));
}

test "engine thread: wait fails on timeout instead of blocking until the script ends" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var hold = Hold{ .cap_ms = 3000 };
    live.release = &hold.release;
    defer live.close();

    try install(id, "hostHold", Hold.cb, &hold);
    try startThread(&live);

    var poster = Poster{ .id = id, .src = "hostHold()" };
    const poster_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&hold.entered, 1000) or !spinUntil(&poster.returned, 1000)) {
        std.debug.print("timeout setup: post did not return while the callback was held\n", .{});
        std.process.exit(1);
    }
    poster_thread.join();
    const job = poster.job.load(.seq_cst);
    try testing.expect(job != 0);

    var waiter = Waiter{ .id = id, .job = job, .timeout_ms = 80 };
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.go, .{&waiter});
    // 80ms is the API timeout. 1000ms is only the harness deadline so a wait that ignores timeout_ms still fails instead of hanging the suite.
    joinOrExit(waiter_thread, &waiter.done, 1000, "testThreadWait timeout");
    try testing.expectEqual(jsbay_timeout, waiter.status);
    try testing.expect(!hold.finished.load(.seq_cst));
    try testing.expect(waiter.elapsed_ms < 1000);

    hold.release.store(true, .seq_cst);
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    try testing.expectEqual(jsbay_ok, testThreadWait(id, job, 2000, &result, &err));
    c_api.test_only.freeCString(result);
    c_api.test_only.freeCString(err);
}

test "engine thread: repeated run timeouts release their hidden jobs after execution" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var hold = Hold{ .cap_ms = 5000 };
    live.release = &hold.release;
    defer live.close();

    try install(id, "hostHold", Hold.cb, &hold);
    try startThread(&live);

    var first = Poster{ .id = id, .src = "hostHold()" };
    const held_thread = try std.Thread.spawn(.{}, Poster.go, .{&first});
    if (!spinUntil(&hold.entered, 1000) or !spinUntil(&first.returned, 1000)) {
        std.debug.print("run timeout setup: callback did not hold the engine thread\n", .{});
        std.process.exit(1);
    }
    held_thread.join();

    var run1 = RunJob{ .id = id, .src = "1+1", .filename = "<run-timeout-1>", .timeout_ms = 15 };
    var run2 = RunJob{ .id = id, .src = "2+2", .filename = "<run-timeout-2>", .timeout_ms = 15 };
    var run3 = RunJob{ .id = id, .src = "3+3", .filename = "<run-timeout-3>", .timeout_ms = 15 };
    const t1 = try std.Thread.spawn(.{}, RunJob.go, .{&run1});
    const t2 = try std.Thread.spawn(.{}, RunJob.go, .{&run2});
    const t3 = try std.Thread.spawn(.{}, RunJob.go, .{&run3});
    joinOrExit(t1, &run1.done, 1000, "first testThreadRun timeout");
    joinOrExit(t2, &run2.done, 1000, "second testThreadRun timeout");
    joinOrExit(t3, &run3.done, 1000, "third testThreadRun timeout");
    try testing.expectEqual(jsbay_timeout, run1.status);
    try testing.expectEqual(jsbay_timeout, run2.status);
    try testing.expectEqual(jsbay_timeout, run3.status);
    try testing.expectEqual(@as(usize, 4), engine_thread_mod.jobCountForTesting(id));

    hold.release.store(true, .seq_cst);
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    try testing.expectEqual(jsbay_ok, testThreadWait(id, first.job.load(.seq_cst), 2000, &result, &err));
    const deadline = io.monotonicMilliseconds() + 2000;
    while (engine_thread_mod.jobCountForTesting(id) != 0) {
        if (io.monotonicMilliseconds() >= deadline) return error.TimedOutRunJobsWereNotReleased;
        io.sleepMs(1);
    }
    try testing.expectEqual(@as(usize, 0), engine_thread_mod.jobCountForTesting(id));
}

test "engine thread: stop reaps timed out run jobs that never execute" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var hold = Hold{ .cap_ms = 5000 };
    live.release = &hold.release;
    defer live.close();

    try install(id, "hostHold", Hold.cb, &hold);
    try startThread(&live);
    var first = Poster{ .id = id, .src = "hostHold()" };
    const held_thread = try std.Thread.spawn(.{}, Poster.go, .{&first});
    if (!spinUntil(&hold.entered, 1000) or !spinUntil(&first.returned, 1000)) {
        std.debug.print("stop hidden-job setup: callback did not block the engine thread\n", .{});
        std.process.exit(1);
    }
    held_thread.join();

    var run1 = RunJob{ .id = id, .src = "1", .filename = "<cancelled-run-1>", .timeout_ms = 10 };
    var run2 = RunJob{ .id = id, .src = "2", .filename = "<cancelled-run-2>", .timeout_ms = 10 };
    const t1 = try std.Thread.spawn(.{}, RunJob.go, .{&run1});
    const t2 = try std.Thread.spawn(.{}, RunJob.go, .{&run2});
    joinOrExit(t1, &run1.done, 1000, "first queued run timeout");
    joinOrExit(t2, &run2.done, 1000, "second queued run timeout");
    try testing.expectEqual(jsbay_timeout, run1.status);
    try testing.expectEqual(jsbay_timeout, run2.status);

    const Stop = struct {
        fn go(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine_thread_mod.threadStop(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var stop_done = std.atomic.Value(bool).init(false);
    const stop_thread = try std.Thread.spawn(.{}, Stop.go, .{ id, &stop_done });
    const reap_deadline = io.monotonicMilliseconds() + 1000;
    while (engine_thread_mod.jobCountForTesting(id) != 1) {
        if (io.monotonicMilliseconds() >= reap_deadline) {
            std.debug.print("stop did not reap hidden run jobs before releasing the host callback\n", .{});
            std.process.exit(1);
        }
        io.sleepMs(1);
    }
    hold.release.store(true, .seq_cst);
    joinOrExit(stop_thread, &stop_done, 2000, "stop did not finish after releasing callback");
    live.started = false;
    // The completed hostHold post was never waited on, so its explicit job remains owned by this instance. The timed-out runScript jobs have no public ids and must be reaped by stop.
    try testing.expectEqual(@as(usize, 1), engine_thread_mod.jobCountForTesting(id));
}

const NativeCount = struct {
    calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn countNativeTask(data: ?*anyopaque) void {
    const counter: *NativeCount = @ptrCast(@alignCast(data.?));
    _ = counter.calls.fetchAdd(1, .seq_cst);
}

test "engine thread: stop cancels a pending native task before restart" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var hold = Hold{ .cap_ms = 5000 };
    live.release = &hold.release;
    defer live.close();

    try install(id, "hostHold", Hold.cb, &hold);
    try startThread(&live);
    var first = Poster{ .id = id, .src = "hostHold()" };
    const held_thread = try std.Thread.spawn(.{}, Poster.go, .{&first});
    if (!spinUntil(&hold.entered, 1000) or !spinUntil(&first.returned, 1000)) {
        std.debug.print("native stop setup: callback did not block the engine thread\n", .{});
        std.process.exit(1);
    }
    held_thread.join();

    var counter = NativeCount{};
    try testing.expect(engine_thread_mod.postToEngineThread(id, countNativeTask, &counter));
    const Stop = struct {
        fn go(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine_thread_mod.threadStop(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var stop_done = std.atomic.Value(bool).init(false);
    const stop_thread = try std.Thread.spawn(.{}, Stop.go, .{ id, &stop_done });
    const cancel_deadline = io.monotonicMilliseconds() + 1000;
    while (engine_thread_mod.nativeTaskPendingForTesting(id)) {
        if (io.monotonicMilliseconds() >= cancel_deadline) {
            std.debug.print("stop did not cancel the queued native task before releasing the host callback\n", .{});
            std.process.exit(1);
        }
        io.sleepMs(1);
    }
    hold.release.store(true, .seq_cst);
    joinOrExit(stop_thread, &stop_done, 2000, "stop did not finish after releasing callback");
    live.started = false;

    try startThread(&live);
    var fresh = NativeCount{};
    try testing.expect(engine_thread_mod.postToEngineThread(id, countNativeTask, &fresh));
    const deadline = io.monotonicMilliseconds() + 1000;
    while (fresh.calls.load(.seq_cst) == 0) {
        if (io.monotonicMilliseconds() >= deadline) return error.RestartedNativeTaskDidNotRun;
        io.sleepMs(1);
    }
    try testing.expectEqual(@as(u32, 0), counter.calls.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), fresh.calls.load(.seq_cst));
}

test "engine thread: destroy unblocks a waiter with failure" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var hold = Hold{ .cap_ms = 3000 };
    var live = try createInstance(id);
    // Destroy is the subject of this test. close() only runs if destroy did not.
    defer live.close();

    try install(id, "hostHold", Hold.cb, &hold);
    try startThread(&live);
    live.release = &hold.release;

    var poster = Poster{ .id = id, .src = "hostHold()" };
    const poster_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&hold.entered, 1000) or !spinUntil(&poster.returned, 1000)) {
        std.debug.print("destroy setup: post did not return while the callback was held\n", .{});
        std.process.exit(1);
    }
    poster_thread.join();
    const job = poster.job.load(.seq_cst);
    try testing.expect(job != 0);

    var waiter = Waiter{ .id = id, .job = job, .timeout_ms = 10_000 };
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.go, .{&waiter});
    if (!spinUntil(&waiter.calling, 1000)) {
        std.debug.print("destroy setup: waiter did not block\n", .{});
        std.process.exit(1);
    }

    const Destroy = struct {
        fn go(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine.destroy(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var destroy_done = std.atomic.Value(bool).init(false);
    const destroy_thread = try std.Thread.spawn(.{}, Destroy.go, .{ id, &destroy_done });

    const woke = spinUntil(&waiter.done, 500);
    // The callback is still held here unless destroy itself finished the script. Unblock it only after scoring the waiter, so destroy cannot pass by waiting out the callback.
    hold.release.store(true, .seq_cst);
    if (!woke) {
        std.debug.print("jsbay_engine_destroy did not unblock testThreadWait\n", .{});
        std.process.exit(1);
    }
    joinOrExit(waiter_thread, &waiter.done, 1000, "waiter after destroy");
    joinOrExit(destroy_thread, &destroy_done, 3000, "jsbay_engine_destroy");
    live.closed = true;
    live.started = false;
    try testing.expectEqual(jsbay_destroyed, waiter.status);
}

test "engine_thread: stop wakes a blocked wait without destroying the instance" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var hold = Hold{ .cap_ms = 3000 };
    live.release = &hold.release;
    defer live.close();

    try install(id, "hostHold", Hold.cb, &hold);
    try startThread(&live);

    var poster = Poster{ .id = id, .src = "hostHold()" };
    const poster_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&hold.entered, 1000) or !spinUntil(&poster.returned, 1000)) {
        std.debug.print("stop setup: post did not return while the callback was held\n", .{});
        std.process.exit(1);
    }
    poster_thread.join();
    const job = poster.job.load(.seq_cst);
    try testing.expect(job != 0);

    var waiter = Waiter{ .id = id, .job = job, .timeout_ms = 10_000 };
    const waiter_thread = try std.Thread.spawn(.{}, Waiter.go, .{&waiter});
    if (!spinUntil(&waiter.calling, 1000)) {
        std.debug.print("stop setup: waiter did not block\n", .{});
        std.process.exit(1);
    }

    const Stop = struct {
        fn go(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine_thread_mod.threadStop(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var stop_done = std.atomic.Value(bool).init(false);
    const stop_thread = try std.Thread.spawn(.{}, Stop.go, .{ id, &stop_done });

    // stop runs on this side thread, which is not inside wait/barrier/run. The waiter must observe destruction of the *job* before the held callback is released, and before the instance itself is destroyed.
    joinOrExit(waiter_thread, &waiter.done, 2000, "internal threadStop did not wake testThreadWait");
    try testing.expectEqual(jsbay_destroyed, waiter.status);
    try testing.expect(!hold.finished.load(.seq_cst));
    try testing.expect(!stop_done.load(.seq_cst));

    hold.release.store(true, .seq_cst);
    joinOrExit(stop_thread, &stop_done, 2000, "internal threadStop");
    live.started = false;

    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = testThreadEvalCString(id, "6*7", 3, "<after-stop>".ptr, "<after-stop>".len, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    if (status != jsbay_ok) {
        const msg = if (err) |p| std.mem.span(p) else "";
        std.debug.print("instance did not survive internal threadStop status={d} err={s}\n", .{ status, msg });
    }
    try testing.expectEqual(jsbay_ok, status);
    const text = std.mem.span(result orelse return error.MissingResult);
    try testing.expectEqualStrings("42", text);
    // live.close destroys the instance that stop left alive.
}

test "engine_thread: threadStop preserves user interrupt and execution deadline" {
    try skipSpikeUnlessGreen();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    try startThread(&live);
    try testing.expect(runtime_control.setExecutionTimeLimit(id, 5_000));
    const deadline = runtime_control.executionDeadlineMillis(id) orelse return error.NoDeadline;
    if (runtime_control.supportsMidScriptUserInterrupt()) {
        try testing.expect(runtime_control.requestInterrupt(id));
    } else {
        // Spike honesty: requestInterrupt returns false and does not arm a mid-script bit.
        try testing.expect(!runtime_control.requestInterrupt(id));
        try testing.expect(!runtime_control.isInterruptRequested(id));
    }

    engine_thread_mod.threadStop(id);
    live.started = false;
    if (runtime_control.supportsMidScriptUserInterrupt()) {
        try testing.expect(runtime_control.isInterruptRequested(id));
        try testing.expect(runtime_control.clearInterrupt(id));
        try testing.expect(!runtime_control.isInterruptRequested(id));
    } else {
        try testing.expect(!runtime_control.isInterruptRequested(id));
    }
    try testing.expectEqual(deadline, runtime_control.executionDeadlineMillis(id).?);
    try testing.expect(runtime_control.setExecutionTimeLimit(id, 0));

    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = testThreadEvalCString(id, "6*7", 3, "<after-stop-bits>".ptr, "<after-stop-bits>".len, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    if (status != jsbay_ok) {
        const msg = if (err) |e| std.mem.span(e) else "(null)";
        std.debug.print("after-stop-bits status={d} err={s} interrupt={any} deadline={any}\n", .{
            status,
            msg,
            runtime_control.isInterruptRequested(id),
            runtime_control.executionDeadlineMillis(id),
        });
    }
    try testing.expectEqual(jsbay_ok, status);
    try testing.expectEqualStrings("42", std.mem.span(result orelse return error.MissingResult));
    try startThread(&live);
    try expectRun(id, "40+2", "42");
}

test "engine_thread: stop interrupts an executing infinite script and permits restart" {
    try skipSpikeNeedsNativeInterrupt();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    var entered = EnteredProbe{};
    try install(id, "hostEntered", EnteredProbe.cb, &entered);
    try startThread(&live);

    var run = RunJob{ .id = id, .src = "hostEntered(); while (true) {}", .filename = "<stop-infinite>", .timeout_ms = 10_000 };
    const run_thread = try std.Thread.spawn(.{}, RunJob.go, .{&run});
    if (!spinUntil(&entered.entered, 1_000)) {
        std.debug.print("infinite script did not enter host callback\n", .{});
        std.process.exit(1);
    }
    const Stop = struct {
        fn go(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine_thread_mod.threadStop(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var stopped = std.atomic.Value(bool).init(false);
    const stop_thread = try std.Thread.spawn(.{}, Stop.go, .{ id, &stopped });
    joinOrExit(run_thread, &run.done, 3_000, "infinite script did not observe threadStop");
    joinOrExit(stop_thread, &stopped, 3_000, "threadStop did not join interrupted script");
    live.started = false;
    try testing.expect(run.status == jsbay_exception or run.status == jsbay_destroyed);

    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const sync_status = testThreadEvalCString(id, "6*7", 3, "<after-stop>".ptr, "<after-stop>".len, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    try testing.expectEqual(jsbay_ok, sync_status);
    try testing.expectEqualStrings("42", std.mem.span(result orelse return error.MissingResult));
    try startThread(&live);
    try expectRun(id, "40+2", "42");
}

test "engine_thread: destroy interrupts an executing infinite script" {
    try skipSpikeNeedsNativeInterrupt();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    var entered = EnteredProbe{};
    try install(id, "hostEntered", EnteredProbe.cb, &entered);
    try startThread(&live);

    var run = RunJob{ .id = id, .src = "hostEntered(); while (true) {}", .filename = "<destroy-infinite>", .timeout_ms = 10_000 };
    const run_thread = try std.Thread.spawn(.{}, RunJob.go, .{&run});
    if (!spinUntil(&entered.entered, 1_000)) {
        std.debug.print("destroying infinite script did not enter host callback\n", .{});
        std.process.exit(1);
    }
    const Destroy = struct {
        fn go(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine.destroy(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var destroyed = std.atomic.Value(bool).init(false);
    const destroy_thread = try std.Thread.spawn(.{}, Destroy.go, .{ id, &destroyed });
    joinOrExit(run_thread, &run.done, 3_000, "infinite script did not observe destroy");
    joinOrExit(destroy_thread, &destroyed, 3_000, "destroy did not join interrupted script");
    live.started = false;
    live.closed = true;
    try testing.expect(run.status == jsbay_exception or run.status == jsbay_destroyed);
    try testing.expect(engine.getContext(id) == null);
}

const StopFromHost = struct {
    returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cb(
        instance_id: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *StopFromHost = @ptrCast(@alignCast(user.?));
        engine_thread_mod.threadStop(instance_id);
        self.returned.store(true, .seq_cst);
        clearHost(out);
        return 0;
    }
};

test "engine_thread: host callback stop leaves the instance usable after its callback returns" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    var stop = StopFromHost{};
    try install(id, "hostStop", StopFromHost.cb, &stop);
    try startThread(&live);

    var stopped_result: ?[*:0]u8 = null;
    var stopped_error: ?[*:0]u8 = null;
    const stopped_status = testThreadRun(
        id,
        "hostStop()".ptr,
        "hostStop()".len,
        "<host-stop>".ptr,
        "<host-stop>".len,
        2_000,
        &stopped_result,
        &stopped_error,
    );
    defer c_api.test_only.freeCString(stopped_result);
    defer c_api.test_only.freeCString(stopped_error);
    try testing.expectEqual(jsbay_destroyed, stopped_status);
    try testing.expect(spinUntil(&stop.returned, 1_000));

    const stopped_deadline = io.monotonicMilliseconds() + 1_000;
    while (testThreadId(id) != 0) {
        if (io.monotonicMilliseconds() >= stopped_deadline) return error.EngineThreadDidNotExitAfterHostStop;
        io.sleepMs(1);
    }
    live.started = false;

    var sync_result: ?[*:0]u8 = null;
    var sync_error: ?[*:0]u8 = null;
    const sync_status = testThreadEvalCString(id, "6*7", 3, "<after-host-stop>".ptr, "<after-host-stop>".len, &sync_result, &sync_error);
    defer c_api.test_only.freeCString(sync_result);
    defer c_api.test_only.freeCString(sync_error);
    try testing.expectEqual(jsbay_ok, sync_status);
    try testing.expectEqualStrings("42", std.mem.span(sync_result orelse return error.MissingResult));

    try startThread(&live);
    try expectRun(id, "40+2", "42");
}

test "engine_thread: callback stop interrupts JavaScript that continues after the callback" {
    try skipSpikeNeedsNativeInterrupt();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    var stop = StopFromHost{};
    try install(id, "hostStop", StopFromHost.cb, &stop);
    try startThread(&live);

    var run = RunJob{ .id = id, .src = "hostStop(); while (true) {}", .filename = "<self-stop-infinite>", .timeout_ms = 10_000 };
    const thread = try std.Thread.spawn(.{}, RunJob.go, .{&run});
    joinOrExit(thread, &run.done, 3_000, "self-stop did not interrupt JavaScript");
    live.started = false;
    try testing.expectEqual(jsbay_destroyed, run.status);
    try testing.expect(stop.returned.load(.seq_cst));
}

const ShutdownBeforeLifePause = struct {
    claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn hook(data: ?*anyopaque) void {
        const self: *ShutdownBeforeLifePause = @ptrCast(@alignCast(data.?));
        if (self.claimed.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return;
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) std.atomic.spinLoopHint();
    }
};

const StopAfterExternalShutdown = struct {
    pause: *const ShutdownBeforeLifePause,
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cb(
        instance_id: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *StopAfterExternalShutdown = @ptrCast(@alignCast(user.?));
        self.entered.store(true, .seq_cst);
        while (!self.pause.entered.load(.seq_cst)) std.atomic.spinLoopHint();
        engine_thread_mod.threadStop(instance_id);
        self.returned.store(true, .seq_cst);
        clearHost(out);
        return 0;
    }
};

const StopRunner = struct {
    id: i32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *@This()) void {
        engine_thread_mod.threadStop(self.id);
        self.done.store(true, .seq_cst);
    }
};

test "engine_thread: an older stop cannot join a replacement started after callback stop" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    var pause = ShutdownBeforeLifePause{};
    var callback = StopAfterExternalShutdown{ .pause = &pause };
    try install(id, "hostStopAfterExternalShutdown", StopAfterExternalShutdown.cb, &callback);
    try startThread(&live);
    try testing.expect(engine_thread_mod.setShutdownBeforeLifeHookForTesting(id, ShutdownBeforeLifePause.hook, &pause));

    var poster = Poster{ .id = id, .src = "hostStopAfterExternalShutdown()" };
    const poster_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&poster.returned, 1_000)) {
        std.debug.print("stop race setup: post did not return\n", .{});
        std.process.exit(1);
    }
    poster_thread.join();

    if (!spinUntil(&callback.entered, 1_000)) {
        std.debug.print("stop race setup: host callback did not enter before external stop\n", .{});
        std.process.exit(1);
    }
    var external_stop = StopRunner{ .id = id };
    const external_thread = try std.Thread.spawn(.{}, StopRunner.run, .{&external_stop});
    if (!spinUntil(&pause.entered, 1_000)) {
        std.debug.print("stop race setup: external stop did not reach the pre-life barrier\n", .{});
        std.process.exit(1);
    }
    if (!spinUntil(&callback.returned, 1_000)) {
        std.debug.print("stop race setup: callback stop did not return\n", .{});
        std.process.exit(1);
    }
    const exited_deadline = io.monotonicMilliseconds() + 1_000;
    while (testThreadId(id) != 0) {
        if (io.monotonicMilliseconds() >= exited_deadline) {
            std.debug.print("stop race setup: callback stop did not let the engine thread exit\n", .{});
            std.process.exit(1);
        }
        io.sleepMs(1);
    }

    // This second stop has no thread left to join, so it may return. It must not clear the older stop's admission block while that stop is paused.
    var second_stop = StopRunner{ .id = id };
    const second_thread = try std.Thread.spawn(.{}, StopRunner.run, .{&second_stop});
    joinOrExit(second_thread, &second_stop.done, 1_000, "second overlapping stop did not return");

    const restart_accepted = engine_thread_mod.threadStart(id);
    if (restart_accepted) {
        // Stop an unexpectedly admitted replacement so the paused stop cannot leave the test process waiting on a live thread.
        var cleanup_stop = StopRunner{ .id = id };
        const cleanup_thread = try std.Thread.spawn(.{}, StopRunner.run, .{&cleanup_stop});
        pause.release.store(true, .seq_cst);
        joinOrExit(external_thread, &external_stop.done, 2_000, "older stop did not finish after cleanup stop");
        joinOrExit(cleanup_thread, &cleanup_stop.done, 2_000, "cleanup stop did not finish");
    } else {
        pause.release.store(true, .seq_cst);
        joinOrExit(external_thread, &external_stop.done, 2_000, "older stop did not finish");
    }
    live.started = false;

    try testing.expect(!restart_accepted);
    try startThread(&live);
    try expectRun(id, "40+2", "42");
}

const DestroyFromHost = struct {
    wait_for_waiter: bool = false,
    on_engine_thread: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    destroy_entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    callback_returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cb(
        instance_id: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *DestroyFromHost = @ptrCast(@alignCast(user.?));
        if (self.wait_for_waiter) {
            const deadline = io.monotonicMilliseconds() + 2_000;
            while (!engine_thread_mod.hasJobWaiterForTesting(instance_id)) {
                if (io.monotonicMilliseconds() >= deadline) {
                    std.debug.print("host destroy did not observe a registered job waiter\n", .{});
                    std.process.exit(1);
                }
                std.Thread.yield() catch {};
            }
        }
        const engine_thread = testThreadId(instance_id);
        self.on_engine_thread.store(engine_thread != 0 and engine_thread == thisThreadId(), .seq_cst);
        self.destroy_entered.store(true, .seq_cst);
        engine.destroy(instance_id);
        // No engine API after destroy. A number return forces the trampoline to build a JS value on the way back into the caller.
        out.* = .{
            .tag = host_number,
            .reserved = 0,
            .number = 1,
            .ptr = null,
            .len = 0,
        };
        self.callback_returned.store(true, .seq_cst);
        return 0;
    }
};

const JoinDestroy = struct {
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cb(
        instance_id: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *JoinDestroy = @ptrCast(@alignCast(user.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) io.sleepMs(1);
        engine.destroy(instance_id);
        self.returned.store(true, .seq_cst);
        clearHost(out);
        return 0;
    }
};

const ExternalDestroy = struct {
    id: i32,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn go(self: *ExternalDestroy) void {
        self.started.store(true, .seq_cst);
        engine.destroy(self.id);
        self.done.store(true, .seq_cst);
    }
};

const DetachedPause = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn hook(data: ?*anyopaque) void {
        const self: *DetachedPause = @ptrCast(@alignCast(data.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) io.sleepMs(1);
    }
};

const DestroyFinalizeCount = struct {
    calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn countDestroyFinalizer(data: ?*anyopaque, _: bool) callconv(.c) void {
    const count: *DestroyFinalizeCount = @ptrCast(@alignCast(data.?));
    _ = count.calls.fetchAdd(1, .seq_cst);
}

test "engine_thread: external join owns teardown when callback requests destroy" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var callback = JoinDestroy{};
    try install(id, "hostJoinDestroy", JoinDestroy.cb, &callback);
    try startThread(&live);

    var poster = Poster{ .id = id, .src = "hostJoinDestroy()" };
    const post_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&callback.entered, 1000) or !spinUntil(&poster.returned, 1000)) {
        std.debug.print("external join setup: callback did not block on the engine thread\n", .{});
        std.process.exit(1);
    }
    post_thread.join();

    var destroy = ExternalDestroy{ .id = id };
    const destroy_thread = try std.Thread.spawn(.{}, ExternalDestroy.go, .{&destroy});
    const join_deadline = io.monotonicMilliseconds() + 2000;
    while (!engine_thread_mod.isJoiningForTesting(id)) {
        if (io.monotonicMilliseconds() >= join_deadline) {
            std.debug.print("external destroy did not enter join\n", .{});
            std.process.exit(1);
        }
        io.sleepMs(1);
    }

    // The callback requests a deferred destroy only after the external destroy has claimed the join path. Both owners must finish without waiting for each other's State reference.
    callback.release.store(true, .seq_cst);
    joinOrExit(destroy_thread, &destroy.done, 2000, "external destroy deadlocked with callback destroy");
    cleanup = false;
    live.closed = true;
    live.started = false;
    try testing.expect(callback.returned.load(.seq_cst));
    try testing.expect(destroy.done.load(.seq_cst));
}

test "engine_thread: thread stop owns teardown when callback requests destroy" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var callback = JoinDestroy{};
    try install(id, "hostStopDestroy", JoinDestroy.cb, &callback);
    try startThread(&live);

    var poster = Poster{ .id = id, .src = "hostStopDestroy()" };
    const post_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&callback.entered, 1000) or !spinUntil(&poster.returned, 1000)) {
        std.debug.print("thread stop setup: callback did not block on the engine thread\n", .{});
        std.process.exit(1);
    }
    post_thread.join();

    const Stop = struct {
        id: i32,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn go(self: *@This()) void {
            engine_thread_mod.threadStop(self.id);
            self.done.store(true, .seq_cst);
        }
    };
    var stop = Stop{ .id = id };
    const stop_thread = try std.Thread.spawn(.{}, Stop.go, .{&stop});
    const join_deadline = io.monotonicMilliseconds() + 2000;
    while (!engine_thread_mod.isJoiningForTesting(id)) {
        if (io.monotonicMilliseconds() >= join_deadline) {
            std.debug.print("thread stop did not enter join\n", .{});
            std.process.exit(1);
        }
        io.sleepMs(1);
    }

    callback.release.store(true, .seq_cst);
    joinOrExit(stop_thread, &stop.done, 3000, "thread stop deadlocked with callback destroy");
    cleanup = false;
    live.closed = true;
    live.started = false;
    try testing.expect(callback.returned.load(.seq_cst));
    try testing.expect(stop.done.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}

test "engine_thread: deferred teardown keeps destroy ownership through runtime removal" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    try helpers.evalOk(id, "globalThis.finalizeOnDestroy = {};");
    var finalized = DestroyFinalizeCount{};
    {
        const ctx = engine.getContext(id) orelse return error.NoContext;
        const global = ActiveEngine.getGlobalObject(ctx);
        defer ActiveEngine.freeValue(ctx, global);
        const target = ActiveEngine.getPropertyVal(ctx, global, "finalizeOnDestroy") orelse return error.NoTarget;
        try testing.expect(weakcb.attachDestroyingFinalizer(id, target, @ptrCast(&finalized), countDestroyFinalizer));
        ActiveEngine.freeValue(ctx, target);
    }

    var callback = DestroyFromHost{};
    try install(id, "hostDestroy", DestroyFromHost.cb, &callback);
    try startThread(&live);
    var pause = DetachedPause{};
    try testing.expect(engine_thread_mod.setDetachedTeardownHookForTesting(id, DetachedPause.hook, &pause));

    var poster = Poster{ .id = id, .src = "hostDestroy()" };
    const post_thread = try std.Thread.spawn(.{}, Poster.go, .{&poster});
    if (!spinUntil(&poster.returned, 1000)) {
        std.debug.print("deferred teardown setup: post did not return\n", .{});
        std.process.exit(1);
    }
    post_thread.join();
    if (!spinUntil(&pause.entered, 2000)) {
        std.debug.print("engine-thread cleanup did not reach the detached-state barrier\n", .{});
        std.process.exit(1);
    }

    var second_destroy = ExternalDestroy{ .id = id };
    const second_thread = try std.Thread.spawn(.{}, ExternalDestroy.go, .{&second_destroy});
    const waiter_deadline = io.monotonicMilliseconds() + 1000;
    while (engine_thread_mod.destroyGateWaitersForTesting(id) == 0) {
        if (io.monotonicMilliseconds() >= waiter_deadline) {
            std.debug.print("second destroy did not wait for the deferred teardown owner\n", .{});
            std.process.exit(1);
        }
        io.sleepMs(1);
    }
    try testing.expect(!second_destroy.done.load(.seq_cst));
    pause.release.store(true, .seq_cst);
    joinOrExit(second_thread, &second_destroy.done, 3000, "second destroy did not finish after deferred runtime removal");
    cleanup = false;
    live.closed = true;
    live.started = false;
    try testing.expectEqual(@as(u32, 1), finalized.calls.load(.seq_cst));
}

const StillAlive = struct {
    reached_js: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *StillAlive = @ptrCast(@alignCast(user.?));
        self.reached_js.store(true, .seq_cst);
        clearHost(out);
        return 0;
    }
};

const PostAndWait = struct {
    id: i32,
    status: c_int = -1,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn go(self: *PostAndWait) void {
        const src = "hostDestroy(); hostStillAlive()";
        const job = testThreadPost(self.id, src.ptr, src.len, "<destroy-from-host>".ptr, "<destroy-from-host>".len);
        var result: ?[*:0]u8 = null;
        var err: ?[*:0]u8 = null;
        self.status = if (job == 0)
            jsbay_invalid
        else
            testThreadWait(self.id, job, 5_000, &result, &err);
        c_api.test_only.freeCString(result);
        c_api.test_only.freeCString(err);
        self.done.store(true, .seq_cst);
    }
};

test "engine_thread: destroy from the host callback unblocks the waiter and returns to JS" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    // Waiter registration must precede destruction; waiting on an already destroyed instance correctly returns INVALID instead of DESTROYED.
    var dying = DestroyFromHost{ .wait_for_waiter = true };
    var alive = StillAlive{};
    try install(id, "hostDestroy", DestroyFromHost.cb, &dying);
    try install(id, "hostStillAlive", StillAlive.cb, &alive);
    try startThread(&live);

    var waiter = PostAndWait{ .id = id };
    const waiter_thread = try std.Thread.spawn(.{}, PostAndWait.go, .{&waiter});
    // Destroy runs on the engine thread, inside the callback. The harness deadline is the watchdog: a beforeDestroy that waits on its own ref, or a waiter that never wakes, exits instead of hanging the suite.
    joinOrExit(waiter_thread, &waiter.done, 3000, "destroy from host callback did not unblock testThreadWait");
    if (!spinUntil(&dying.callback_returned, 2000)) {
        std.debug.print("jsbay_engine_destroy from the host callback did not return\n", .{});
        std.process.exit(1);
    }
    // Past this point the instance is gone. Do not call stop, destroy, eval, or any other engine API; the waiter status is the only observation.
    cleanup = false;
    live.closed = true;
    live.started = false;

    try testing.expect(dying.on_engine_thread.load(.seq_cst));
    try testing.expect(dying.destroy_entered.load(.seq_cst));
    try testing.expectEqual(jsbay_destroyed, waiter.status);
    if (!spinUntil(&alive.reached_js, 2000)) {
        std.debug.print("host callback did not return to JS after jsbay_engine_destroy\n", .{});
        return error.RuntimeFreedWhileHostCallbackOnStack;
    }
    try testing.expect(alive.reached_js.load(.seq_cst));
}

test "engine_thread: callback destroy interrupts JavaScript that continues after the callback" {
    try skipSpikeNeedsNativeInterrupt();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();
    var destroy = DestroyFromHost{};
    try install(id, "hostDestroy", DestroyFromHost.cb, &destroy);
    try startThread(&live);

    var run = RunJob{ .id = id, .src = "hostDestroy(); while (true) {}", .filename = "<self-destroy-infinite>", .timeout_ms = 10_000 };
    const thread = try std.Thread.spawn(.{}, RunJob.go, .{&run});
    joinOrExit(thread, &run.done, 3_000, "self-destroy did not interrupt JavaScript");
    cleanup = false;
    live.closed = true;
    live.started = false;
    try testing.expectEqual(jsbay_destroyed, run.status);
    try testing.expect(destroy.callback_returned.load(.seq_cst));
    const deadline = io.monotonicMilliseconds() + 3_000;
    while (engine.getContext(id) != null) {
        if (io.monotonicMilliseconds() >= deadline) return error.DeferredDestroyDidNotRemoveRuntime;
        io.sleepMs(1);
    }
}

const DirectEvalDestroy = struct {
    id: i32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *DirectEvalDestroy) void {
        const result = engine.evalScript(self.id, "hostDestroy(); 42", "<direct-destroy-eval>");
        self.result_ok.store(result.err == null and result.result != null and std.mem.eql(u8, result.result.?, "42"), .seq_cst);
        helpers.freeEvalResult(result);
        self.done.store(true, .seq_cst);
    }
};

const DirectInfiniteEval = struct {
    id: i32,
    done: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),

    fn run(self: *DirectInfiniteEval) void {
        const result = engine.evalScript(self.id, "hostEntered(); while (true) {}", "<direct-infinite>");
        self.interrupted.store(result.err != null, .seq_cst);
        helpers.freeEvalResult(result);
        self.done.store(true, .seq_cst);
    }
};

test "engine_thread: direct eval callback destroy defers runtime free until eval unwinds" {
    try skipEscargotDestroyDefer();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var dying = DestroyFromHost{};
    try install(id, "hostDestroy", DestroyFromHost.cb, &dying);
    var direct = DirectEvalDestroy{ .id = id };
    const eval_thread = try std.Thread.spawn(.{}, DirectEvalDestroy.run, .{&direct});
    joinOrExit(eval_thread, &direct.done, 3000, "destroy from direct eval callback did not unwind");
    cleanup = false;
    live.closed = true;

    try testing.expect(dying.destroy_entered.load(.seq_cst));
    try testing.expect(dying.callback_returned.load(.seq_cst));
    try testing.expect(direct.result_ok.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}

test "engine_thread: destroy interrupts a direct infinite eval without a library thread" {
    try skipSpikeNeedsNativeInterrupt();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();
    var entered = EnteredProbe{};
    try install(id, "hostEntered", EnteredProbe.cb, &entered);
    var direct = DirectInfiniteEval{ .id = id };
    const eval_thread = try std.Thread.spawn(.{}, DirectInfiniteEval.run, .{&direct});
    if (!spinUntil(&entered.entered, 1_000)) {
        std.debug.print("direct infinite eval did not enter host callback\n", .{});
        std.process.exit(1);
    }
    const Destroy = struct {
        fn run(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine.destroy(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var destroyed = std.atomic.Value(bool).init(false);
    const destroy_thread = try std.Thread.spawn(.{}, Destroy.run, .{ id, &destroyed });
    joinOrExit(eval_thread, &direct.done, 3_000, "direct infinite eval did not observe destroy");
    joinOrExit(destroy_thread, &destroyed, 3_000, "destroy did not finish after direct eval");
    cleanup = false;
    live.closed = true;
    try testing.expect(direct.interrupted.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}

const PublicLoopDestroy = struct {
    id: i32,
    done: std.atomic.Value(bool) = .init(false),
    timed: bool,

    fn run(self: *PublicLoopDestroy) void {
        if (self.timed) {
            engine.blockOnLoopFor(self.id, 5_000);
        } else {
            engine.runEventLoop(self.id);
        }
        self.done.store(true, .seq_cst);
    }
};

fn verifyPublicLoopDeferredDestroy(timed: bool) !void {
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var dying = DestroyFromHost{};
    try install(id, "hostDestroy", DestroyFromHost.cb, &dying);
    const setup = engine.evalScript(id, "setInterval(function(){ hostDestroy(); }, 1)", "<public-loop-destroy>");
    defer helpers.freeEvalResult(setup);
    try testing.expect(setup.err == null);

    var loop = PublicLoopDestroy{ .id = id, .timed = timed };
    const loop_thread = try std.Thread.spawn(.{}, PublicLoopDestroy.run, .{&loop});
    joinOrExit(loop_thread, &loop.done, 3000, "public event loop did not exit after callback destroy");
    cleanup = false;
    live.closed = true;

    try testing.expect(dying.destroy_entered.load(.seq_cst));
    try testing.expect(dying.callback_returned.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}

test "engine_thread: public runEventLoop exits when a timer callback destroys its runtime" {
    try skipEscargotEtHost();
    try verifyPublicLoopDeferredDestroy(false);
}

test "engine_thread: public blockOnLoopFor exits when a timer callback destroys its runtime" {
    try skipEscargotEtHost();
    try verifyPublicLoopDeferredDestroy(true);
}

const LoopEnteredHost = struct {
    entered: std.atomic.Value(bool) = .init(false),

    fn cb(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *LoopEnteredHost = @ptrCast(@alignCast(user.?));
        self.entered.store(true, .seq_cst);
        clearHost(out);
        return 0;
    }
};

const PublicLoopRunner = struct {
    id: i32,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *PublicLoopRunner) void {
        engine.runEventLoop(self.id);
        self.done.store(true, .seq_cst);
    }
};

const ExternalDestroyRunner = struct {
    id: i32,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ExternalDestroyRunner) void {
        engine.destroy(self.id);
        self.done.store(true, .seq_cst);
    }
};

test "engine_thread: external destroy wakes a public loop before detaching its state" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var entered = LoopEnteredHost{};
    try install(id, "hostLoopEntered", LoopEnteredHost.cb, &entered);
    const setup = engine.evalScript(id, "setInterval(function(){ hostLoopEntered(); }, 1)", "<external-loop-destroy>");
    defer helpers.freeEvalResult(setup);
    try testing.expect(setup.err == null);

    var loop = PublicLoopRunner{ .id = id };
    const loop_thread = try std.Thread.spawn(.{}, PublicLoopRunner.run, .{&loop});
    if (!spinUntil(&entered.entered, 2000)) {
        std.debug.print("public loop timer callback did not run\n", .{});
        std.process.exit(1);
    }

    var destroy = ExternalDestroyRunner{ .id = id };
    const destroy_thread = try std.Thread.spawn(.{}, ExternalDestroyRunner.run, .{&destroy});
    joinOrExit(destroy_thread, &destroy.done, 3000, "external destroy did not finish after waking the public loop");
    joinOrExit(loop_thread, &loop.done, 3000, "public loop did not exit after external destroy");
    cleanup = false;
    live.closed = true;
    try testing.expect(engine.getContext(id) == null);
}

const NestedEvalDestroy = struct {
    id_a: i32,
    id_b: i32,
    nested_eval_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn enterB(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *NestedEvalDestroy = @ptrCast(@alignCast(user.?));
        const result = engine.evalScript(self.id_b, "destroyNestedInstances(); 42", "<nested-destroy-b>");
        self.nested_eval_ok.store(result.err == null and result.result != null and std.mem.eql(u8, result.result.?, "42"), .seq_cst);
        helpers.freeEvalResult(result);
        clearHost(out);
        return 0;
    }

    fn destroyBoth(
        _: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *NestedEvalDestroy = @ptrCast(@alignCast(user.?));
        engine.destroy(self.id_b);
        engine.destroy(self.id_a);
        out.* = .{
            .tag = host_number,
            .reserved = 0,
            .number = 1,
            .ptr = null,
            .len = 0,
        };
        return 0;
    }
};

test "engine_thread: nested direct eval destroys each deferred instance" {
    try skipSpikeUnlessGreen();
    const id_a = helpers.nextInstanceId();
    const id_b = helpers.nextInstanceId();
    var live_a = try createInstance(id_a);
    var cleanup_a = true;
    errdefer if (cleanup_a) live_a.close();
    var live_b = try createInstance(id_b);
    var cleanup_b = true;
    errdefer if (cleanup_b) live_b.close();

    var nested = NestedEvalDestroy{ .id_a = id_a, .id_b = id_b };
    try install(id_a, "enterNestedB", NestedEvalDestroy.enterB, &nested);
    try install(id_b, "destroyNestedInstances", NestedEvalDestroy.destroyBoth, &nested);

    const result = engine.evalScript(id_a, "enterNestedB(); 42", "<nested-destroy-a>");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null and result.result != null and std.mem.eql(u8, result.result.?, "42"));
    try testing.expect(nested.nested_eval_ok.load(.seq_cst));
    try testing.expect(engine.getContext(id_b) == null);
    try testing.expect(engine.getContext(id_a) == null);
    cleanup_a = false;
    cleanup_b = false;
    live_a.closed = true;
    live_b.closed = true;
}

const UnstartedEval = struct {
    id: i32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *UnstartedEval) void {
        const result = engine.evalScript(self.id, "holdEval(); 42", "<unstarted-destroy-eval>");
        self.result_ok.store(result.err == null and result.result != null and std.mem.eql(u8, result.result.?, "42"), .seq_cst);
        helpers.freeEvalResult(result);
        self.done.store(true, .seq_cst);
    }
};

const ExternalDestroyEval = struct {
    id: i32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ExternalDestroyEval) void {
        engine.destroy(self.id);
        self.done.store(true, .seq_cst);
    }
};

test "engine_thread: destroy waits for an unstarted direct eval lease" {
    try skipEscargotDestroyDefer();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var hold = Hold{ .cap_ms = 5000 };
    try install(id, "holdEval", Hold.cb, &hold);
    var eval = UnstartedEval{ .id = id };
    const eval_thread = try std.Thread.spawn(.{}, UnstartedEval.run, .{&eval});
    const entered = spinUntil(&hold.entered, 2000);
    var destroy = ExternalDestroyEval{ .id = id };
    const destroy_thread = try std.Thread.spawn(.{}, ExternalDestroyEval.run, .{&destroy});
    _ = spinUntil(&destroy.done, 200);
    const destroy_returned_while_eval_active = destroy.done.load(.seq_cst);

    hold.release.store(true, .seq_cst);
    joinOrExit(eval_thread, &eval.done, 3000, "unstarted eval did not unwind");
    joinOrExit(destroy_thread, &destroy.done, 3000, "external destroy did not finish after eval lease release");
    cleanup = false;
    live.closed = true;

    try testing.expect(entered);
    try testing.expect(!destroy_returned_while_eval_active);
    try testing.expect(eval.result_ok.load(.seq_cst));
    try testing.expect(hold.finished.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}

// ---------------------------------------------------------------------------
// 2. Host callbacks installed through the C ABI.
// ---------------------------------------------------------------------------

test "c abi host: callback runs on the engine thread and JS receives its number" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    var probe = AddProbe{};
    // Name length excludes the suffix. A C-string install would miss `hostAdd`.
    const name_storage = "hostAddNOT_THE_NAME";
    const name = name_storage[0.."hostAdd".len];
    try install(id, name, AddProbe.cb, &probe);
    try startThread(&live);

    var job = RunJob{
        .id = id,
        .src = "hostAdd(20, 22) + 1",
        .filename = "<host-add>",
        .timeout_ms = 2000,
    };
    try runOnWorker(&job);
    if (job.status != jsbay_ok) {
        std.debug.print("hostAdd status={d} err={s}\n", .{ job.status, job.err_buf[0..job.err.len] });
    }
    try testing.expectEqual(jsbay_ok, job.status);
    try expectCopied(job.result, &job.result_buf, "43");
    const seen = probe.seen.load(.seq_cst);
    try testing.expectEqual(testThreadId(id), seen);
    try testing.expect(seen != job.caller_thread);
}

test "c abi host: callback string is what the same JS call receives" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    try install(id, "hostEcho", echoCb, null);
    try startThread(&live);

    var job = RunJob{
        .id = id,
        .src = "hostEcho() + \"!\"",
        .filename = "<host-echo>",
        .timeout_ms = 2000,
    };
    try runOnWorker(&job);
    try testing.expectEqual(jsbay_ok, job.status);
    try expectCopied(job.result, &job.result_buf, "pong!");
}

test "JSC c abi host: string arguments preserve values, empty strings, and embedded NUL" {
    if (backend.active_backend != .jsc) return;

    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    var probe = StringArgsProbe{};
    try install(id, "hostStrings", StringArgsProbe.cb, &probe);
    try startThread(&live);

    var job = RunJob{
        .id = id,
        .src = "hostStrings('alpha', '\\u4f60\\u597d', '', 'x' + String.fromCharCode(0) + 'y')",
        .filename = "<host-strings>",
        .timeout_ms = 2000,
    };
    try runOnWorker(&job);
    try testing.expectEqual(jsbay_ok, job.status);
    try expectCopied(job.result, &job.result_buf, "ok");
    try testing.expect(probe.valid);
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "JSC c abi host: more than the inline argument count still cleans string scratch" {
    if (backend.active_backend != .jsc) return;

    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    var probe = ManyStringArgsProbe{};
    try install(id, "hostManyStrings", ManyStringArgsProbe.cb, &probe);
    try startThread(&live);

    var job = RunJob{
        .id = id,
        .src = "String(hostManyStrings('a', 'bb', 'ccc', 'dddd', 'eeeee', 'ffffff', 'ggggggg', 'hhhhhhhh', 'iiiiiiiii'))",
        .filename = "<host-many-strings>",
        .timeout_ms = 2000,
    };
    try runOnWorker(&job);
    try testing.expectEqual(jsbay_ok, job.status);
    try expectCopied(job.result, &job.result_buf, "undefined");
    try testing.expect(probe.valid);
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "c abi host: a callback with no payload is undefined in JS and returns without waiting" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    var probe = NopProbe{};
    try install(id, "hostNop", NopProbe.cb, &probe);
    try startThread(&live);

    const started = io.monotonicMilliseconds();
    var job = RunJob{
        .id = id,
        .src = "String(hostNop())",
        .filename = "<host-nop>",
        .timeout_ms = 2000,
    };
    try runOnWorker(&job);
    const elapsed = io.monotonicMilliseconds() - started;
    try testing.expectEqual(jsbay_ok, job.status);
    try expectCopied(job.result, &job.result_buf, "undefined");
    try testing.expect(probe.entered.load(.seq_cst));
    try testing.expect(probe.elapsed_ms.load(.seq_cst) < 50);
    try testing.expect(elapsed < 1000);
}

test "c abi host: posting and waiting from inside the callback does not deadlock" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    var reentry = Reentry{};
    try install(id, "hostReenter", Reentry.cb, &reentry);
    try startThread(&live);

    var job = RunJob{
        .id = id,
        .src = "hostReenter()",
        .filename = "<host-reenter>",
        .timeout_ms = 2000,
    };
    const worker = try std.Thread.spawn(.{}, RunJob.go, .{&job});
    if (!spinUntil(&job.done, 2500)) {
        std.debug.print(
            "host callback did not finish testThreadPost + testThreadWait (instance lock held across the callback, or the nested job waited behind itself)\n",
            .{},
        );
        std.process.exit(1);
    }
    worker.join();
    if (job.status != jsbay_ok) {
        std.debug.print("reenter status={d} err={s} nested={d}\n", .{
            job.status,
            job.err_buf[0..job.err.len],
            reentry.nested_status.load(.seq_cst),
        });
    }
    try testing.expect(reentry.on_engine_thread.load(.seq_cst));
    try testing.expect(reentry.ok.load(.seq_cst));
    try testing.expectEqual(jsbay_ok, job.status);
    try expectCopied(job.result, &job.result_buf, "1");
}

// ---------------------------------------------------------------------------
// 3. Evaluate bytes plus a source name. No engine thread required.
// ---------------------------------------------------------------------------

test "c abi eval: source length is honored when the buffer is not a C string" {
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    const storage = "2+2; throw new Error(\"past-len\")";
    const src = storage[0..3];
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = testThreadEvalCString(id, src.ptr, src.len, "<len>".ptr, "<len>".len, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    if (status != jsbay_ok) {
        const msg = if (err) |p| std.mem.span(p) else "";
        std.debug.print("testThreadEvalCString length status={d} err={s}\n", .{ status, msg });
    }
    try testing.expectEqual(jsbay_ok, status);
    const text = std.mem.span(result orelse return error.MissingResult);
    try testing.expectEqualStrings("4", text);
}

test "c abi eval: a thrown script reports the filename and not bytes past that length" {
    try skipSpikeUnlessGreen();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    const name_storage = "jsbay_reported_source.jsNOT_PART_OF_NAME";
    const filename = name_storage[0.."jsbay_reported_source.js".len];
    const src = "throw new Error(\"jsbay-marker\")";
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = testThreadEvalCString(id, src.ptr, src.len, filename.ptr, filename.len, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);

    try testing.expectEqual(jsbay_exception, status);
    try testing.expect(result == null);
    const msg = std.mem.span(err orelse return error.MissingError);
    try testing.expect(std.mem.indexOf(u8, msg, "jsbay-marker") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "jsbay_reported_source.js") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "NOT_PART_OF_NAME") == null);
}

test "c abi eval: bytes are the program; a cwd file with the same name is not read or replaced" {
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();

    // Unique across parallel test processes that share one cwd: instance ids restart at the same base, so include the process id.
    var decoy_buf: [96]u8 = undefined;
    const decoy = try std.fmt.bufPrint(
        &decoy_buf,
        "jsbay_eval_bytes_decoy_{d}_{d}.js",
        .{ processIdForPath(), id },
    );
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = decoy, .data = "9+9" });
    defer cwd.deleteFile(testing.io, decoy) catch {};

    const src = "3+3";
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = testThreadEvalCString(id, src.ptr, src.len, decoy.ptr, decoy.len, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    if (status != jsbay_ok) {
        const msg = if (err) |p| std.mem.span(p) else "";
        std.debug.print("testThreadEvalCString decoy status={d} err={s}\n", .{ status, msg });
    }
    try testing.expectEqual(jsbay_ok, status);
    const text = std.mem.span(result orelse return error.MissingResult);
    try testing.expectEqualStrings("6", text);

    const body = try cwd.readFileAlloc(testing.io, decoy, testing.allocator, .limited(64));
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("9+9", body);
}

fn expectRun(id: i32, src: []const u8, expected: []const u8) !void {
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = testThreadRun(
        id,
        src.ptr,
        src.len,
        posted_name.ptr,
        posted_name.len,
        2000,
        &result,
        &err,
    );
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    if (status != jsbay_ok) {
        const msg = if (err) |ptr| std.mem.span(ptr) else "";
        std.debug.print("expectRun status={d} err={s}\n", .{ status, msg });
    }
    try testing.expectEqual(jsbay_ok, status);
    const text = std.mem.span(result orelse return error.MissingResult);
    try testing.expectEqualStrings(expected, text);
}

test "engine thread: posted jobs wake the idle loop" {
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    try startThread(&live);

    // Give the engine thread a chance to reach idle; this test checks job completion after a wake, not the loop's scheduling interval.
    io.sleepMs(5);
    var n: usize = 0;
    while (n < 8) : (n += 1) {
        try expectRun(id, "1+1", "2");
    }
}

test "engine thread: setTimeout fires while the engine thread is idle" {
    try skipEscargotEtHost();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    try startThread(&live);

    try expectRun(id, "globalThis.fired = 0; setTimeout(function(){ globalThis.fired = 1; }, 0); 0", "0");
    // No further job is posted while the timer is outstanding. The idle thread must be blocked in the event loop so the timer callback runs.
    io.sleepMs(30);
    try expectRun(id, "globalThis.fired", "1");
}

const engine_thread_mod = @import("../runtime/engine_thread.zig");

fn currentNativeStackBytes() usize {
    const os = @import("builtin").os.tag;
    switch (os) {
        .macos, .ios, .watchos, .tvos, .visionos => {
            const c = struct {
                extern "c" fn pthread_self() std.c.pthread_t;
                extern "c" fn pthread_get_stacksize_np(std.c.pthread_t) usize;
            };
            return c.pthread_get_stacksize_np(c.pthread_self());
        },
        .linux => {
            const c = struct {
                extern "c" fn pthread_self() std.c.pthread_t;
                extern "c" fn pthread_getattr_np(std.c.pthread_t, *std.c.pthread_attr_t) c_int;
                extern "c" fn pthread_attr_getstacksize(*const std.c.pthread_attr_t, *usize) c_int;
                extern "c" fn pthread_attr_destroy(*std.c.pthread_attr_t) c_int;
            };
            var attr: std.c.pthread_attr_t = undefined;
            if (c.pthread_getattr_np(c.pthread_self(), &attr) != 0) return 0;
            defer _ = c.pthread_attr_destroy(&attr);
            var size: usize = 0;
            if (c.pthread_attr_getstacksize(&attr, &size) != 0) return 0;
            return size;
        },
        else => return 0,
    }
}

const StackProbe = struct {
    size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn run(data: ?*anyopaque) void {
        const self: *StackProbe = @ptrCast(@alignCast(data orelse return));
        self.size.store(currentNativeStackBytes(), .seq_cst);
    }
};

test "engine thread: native stack is at least Harmony's 128MB" {
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    defer live.close();
    try startThread(&live);

    var probe = StackProbe{};
    try testing.expect(engine_thread_mod.postToEngineThread(id, StackProbe.run, &probe));
    var spins: u32 = 0;
    while (probe.size.load(.seq_cst) == 0 and spins < 2000) : (spins += 1) {
        io.sleepMs(1);
    }
    // QuickJS compares the C stack pointer with its JS stack budget. Harmony gives this thread 128MB. The Zig default is 16MB, so a deep call crashes the thread before QuickJS can throw.
    try testing.expect(probe.size.load(.seq_cst) >= 128 * 1024 * 1024);
}
