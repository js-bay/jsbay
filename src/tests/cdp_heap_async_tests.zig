//! Heap usage, heap snapshot chunks, and setTimeout async stacks.
//!
//! `Runtime.getHeapUsage` must report the engine's real used bytes. `HeapProfiler.takeHeapSnapshot` must emit a chunk DevTools can concatenate into a snapshot. With `Debugger.setAsyncCallStackDepth` above zero, a timer callback's console event carries the scheduling stack as `parent`.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const profiler = @import("../inspector/root.zig").profiler;
const sample_hook = @import("../inspector/sample_hook.zig");
const helpers = @import("test_helpers.zig");
const wire = @import("inspector_tests.zig");

const Session = struct {
    alloc: std.mem.Allocator,
    id: i32,
    handle: *inspector.Handle,
    stream: wire.TestStream,
    reader: wire.FrameReader,
    got: std.ArrayList(u8) = .empty,

    fn deinit(self: *Session) void {
        self.got.deinit(self.alloc);
        self.reader.deinit(self.alloc);
        self.stream.close();
        inspector.stop(self.handle);
        engine.destroy(self.id);
    }
};

const ConcurrentEval = struct {
    id: i32,
    source: []const u8,
    filename: []const u8,

    fn run(self: *const ConcurrentEval) void {
        const result = engine.evalScript(self.id, self.source, self.filename);
        if (result.result) |text| std.heap.c_allocator.free(text);
        if (result.err) |text| std.heap.c_allocator.free(text);
    }
};

fn openSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    const id = helpers.nextInstanceId();
    return openSessionWithId(alloc, id, target_id);
}

fn openSessionWithId(alloc: std.mem.Allocator, id: i32, target_id: []const u8) !Session {
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target_id });
    errdefer engine.destroy(id);
    errdefer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{
        .alloc = alloc,
        .id = id,
        .handle = handle,
        .stream = stream,
        .reader = wire.FrameReader.init(stream),
    };
}

fn send(session: *Session, method: []const u8, params: []const u8, id: i64) !void {
    const text = if (params.len == 0)
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method })
    else
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
    defer session.alloc.free(text);
    try wire.writeMaskedText(session.stream, text);
}

fn pump(session: *Session, needle: []const u8) !void {
    try pumpFrom(session, session.got.items.len, needle);
}

fn pumpFrom(session: *Session, start: usize, needle: []const u8) !void {
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        const region = if (start < session.got.items.len) session.got.items[start..] else "";
        if (std.mem.indexOf(u8, region, needle) != null) return;
    }
    std.debug.print("cdp heap/async bytes:\n{s}\n", .{session.got.items});
    return error.TestUnexpectedResult;
}

fn pumpResponse(session: *Session, id: i64) !void {
    const start = session.got.items.len;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, start, id)) return;
    }
    std.debug.print("cdp response id {d} missing:\n{s}\n", .{ id, session.got.items });
    return error.TestUnexpectedResult;
}

fn configureFastProfilerSampling(session: *Session) !void {
    try send(session, "Profiler.setSamplingInterval", "{\"interval\":1}", 0);
    try pumpResponse(session, 0);
}

fn usedSize(payload: []const u8) !i64 {
    const key = "\"usedSize\":";
    const at = std.mem.indexOf(u8, payload, key) orelse return error.TestUnexpectedResult;
    const rest = payload[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return error.TestUnexpectedResult;
    return std.fmt.parseInt(i64, rest[0..end], 10);
}

test "cdp: QuickJS rejects unsupported debugger commands while keeping async stacks available" {
    if (comptime backend.active_backend != .quickjs) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-quickjs-debugger-capabilities");
    defer session.deinit();

    try send(&session, "Debugger.enable", "", 1);
    try pumpResponse(&session, 1);
    try send(&session, "Debugger.setBreakpointByUrl", "{\"url\":\"capabilities.js\",\"lineNumber\":0}", 2);
    try pumpResponse(&session, 2);
    try send(&session, "Debugger.pause", "", 3);
    try pumpResponse(&session, 3);
    try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 4);
    try pumpResponse(&session, 4);

    var seen: [4]bool = @splat(false);
    var messages = std.mem.splitScalar(u8, session.got.items, '\n');
    while (messages.next()) |message| {
        if (message.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, message, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const id = parsed.value.object.get("id") orelse continue;
        if (id != .integer or id.integer < 1 or id.integer > 4) continue;
        seen[@intCast(id.integer - 1)] = true;
        const response = parsed.value.object;
        if (id.integer == 2 or id.integer == 3) {
            try testing.expect(response.get("result") == null);
            const failure = response.get("error") orelse return error.TestUnexpectedResult;
            try testing.expect(failure == .object);
            const code = failure.object.get("code") orelse return error.TestUnexpectedResult;
            const text = failure.object.get("message") orelse return error.TestUnexpectedResult;
            try testing.expect(code == .integer);
            try testing.expect(text == .string and text.string.len != 0);
        } else {
            try testing.expect(response.get("error") == null);
            try testing.expect(response.get("result") != null);
        }
    }
    try testing.expectEqual([4]bool{ true, true, true, true }, seen);
}

test "cdp: getHeapUsage reports bytes the runtime is using" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-heap-usage");
    defer session.deinit();
    const ran = engine.evalScript(session.id, "var heapBlob = new Array(2000); var i = 0; while (i < 2000) { heapBlob[i] = 'heap-usage-pad'; i++; }", "heap.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try send(&session, "Runtime.getHeapUsage", "", 1);
    try pumpResponse(&session, 1);
    const used = try usedSize(session.got.items);
    try testing.expect(used > 0);
}

test "cdp: takeHeapSnapshot emits a chunk with object bytes" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-heap-snap");
    defer session.deinit();
    const ran = engine.evalScript(session.id, "var heapMarker = new ArrayBuffer(12345);", "heap.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try send(&session, "HeapProfiler.takeHeapSnapshot", "", 1);
    try pump(&session, "HeapProfiler.addHeapSnapshotChunk");
    // The completion is a second frame, after the chunk notification.
    try pumpResponse(&session, 1);
    // The chunk is a JSON string, so the snapshot quotes are escaped.
    try testing.expect(std.mem.indexOf(u8, session.got.items, "node_count") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "ArrayBuffer") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "12345") != null);
}

test "cdp: setTimeout console event keeps the scheduling stack when async depth is set" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-async-stack");
    defer session.deinit();
    try send(&session, "Runtime.enable", "", 1);
    try pumpResponse(&session, 1);
    try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    try pumpResponse(&session, 2);
    const src = "function schedule(){ setTimeout(function tick(){ console.log('async-token'); }, 0); } schedule();";
    const ran = engine.evalScript(session.id, src, "async.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try pump(&session, "async-token");
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"description\":\"setTimeout\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"schedule\"") != null);
}

test "cdp: async depth zero does not invent a parent stack" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-async-off");
    defer session.deinit();
    try send(&session, "Runtime.enable", "", 1);
    try pumpResponse(&session, 1);
    const src = "setTimeout(function tick(){ console.log('async-off-token'); }, 0);";
    const ran = engine.evalScript(session.id, src, "async-off.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try pump(&session, "async-off-token");
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"description\":\"setTimeout\"") == null);
}

test "cdp: setInterval console event names the interval parent" {
    if (!backend.isQuickJsApiBackend(backend.active_backend) and !backend.isJscApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-async-interval");
    defer session.deinit();
    try send(&session, "Runtime.enable", "", 1);
    try pumpResponse(&session, 1);
    try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    try pumpResponse(&session, 2);
    const src = "function schedule(){ var id = setInterval(function tick(){ console.log('interval-token'); clearInterval(id); }, 0); } schedule();";
    const ran = engine.evalScript(session.id, src, "interval.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try pump(&session, "interval-token");
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"description\":\"setInterval\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"schedule\"") != null);
}

test "cdp: promise reaction keeps the scheduling stack" {
    if (!backend.isQuickJsApiBackend(backend.active_backend) and !backend.isJscApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-async-promise");
    defer session.deinit();
    try send(&session, "Runtime.enable", "", 1);
    try pumpResponse(&session, 1);
    try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    try pumpResponse(&session, 2);
    const src = "function schedule(){ Promise.resolve().then(function tick(){ console.log('promise-token'); }); } schedule();";
    const ran = engine.evalScript(session.id, src, "promise.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try pump(&session, "promise-token");
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"description\":\"Promise\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"schedule\"") != null);
}

test "cdp: queueMicrotask keeps the scheduling stack" {
    if (!backend.isQuickJsApiBackend(backend.active_backend) and !backend.isJscApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-async-micro");
    defer session.deinit();
    try send(&session, "Runtime.enable", "", 1);
    try pumpResponse(&session, 1);
    try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    try pumpResponse(&session, 2);
    const src = "function schedule(){ queueMicrotask(function tick(){ console.log('micro-token'); }); } schedule();";
    const ran = engine.evalScript(session.id, src, "micro.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try pump(&session, "micro-token");
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"description\":\"queueMicrotask\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"schedule\"") != null);
}

test "cdp: async jobs from two instances keep parents isolated" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var first = try openSession(alloc, "cdp-async-first");
    defer first.deinit();
    var second = try openSession(alloc, "cdp-async-second");
    defer second.deinit();
    try send(&first, "Runtime.enable", "", 1);
    try pumpResponse(&first, 1);
    try send(&second, "Runtime.enable", "", 1);
    try pumpResponse(&second, 1);
    try send(&first, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    try pumpResponse(&first, 2);
    try send(&second, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    try pumpResponse(&second, 2);

    const first_eval = ConcurrentEval{
        .id = first.id,
        .source = "function firstSchedule(){ for (var i = 0; i < 128; i++) Promise.resolve().then(function firstJob(){}); Promise.resolve().then(function firstLog(){ console.log('first-instance-token'); }); } firstSchedule();",
        .filename = "first-instance.js",
    };
    const second_eval = ConcurrentEval{
        .id = second.id,
        .source = "function secondSchedule(){ for (var i = 0; i < 128; i++) queueMicrotask(function secondJob(){}); queueMicrotask(function secondLog(){ console.log('second-instance-token'); }); } secondSchedule();",
        .filename = "second-instance.js",
    };
    const first_thread = try std.Thread.spawn(.{}, ConcurrentEval.run, .{&first_eval});
    const second_thread = try std.Thread.spawn(.{}, ConcurrentEval.run, .{&second_eval});
    first_thread.join();
    second_thread.join();

    try pump(&first, "first-instance-token");
    try pump(&second, "second-instance-token");
    try testing.expect(std.mem.indexOf(u8, first.got.items, "\"functionName\":\"firstSchedule\"") != null);
    try testing.expect(std.mem.indexOf(u8, first.got.items, "\"description\":\"Promise\"") != null);
    try testing.expect(std.mem.indexOf(u8, first.got.items, "secondSchedule") == null);
    try testing.expect(std.mem.indexOf(u8, second.got.items, "\"functionName\":\"secondSchedule\"") != null);
    try testing.expect(std.mem.indexOf(u8, second.got.items, "\"description\":\"queueMicrotask\"") != null);
    try testing.expect(std.mem.indexOf(u8, second.got.items, "firstSchedule") == null);
}

test "cdp: destroying an async instance clears traces before its id is reused" {
    runIdReuseAsyncTraceTest() catch |err| {
        std.debug.print("cdp async id-reuse error: {s}\n", .{@errorName(err)});
        return err;
    };
}

fn runIdReuseAsyncTraceTest() !void {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    const id = helpers.nextInstanceId();
    var stage: []const u8 = "open-stale";
    errdefer std.debug.print("\ncdp async id-reuse failure: id={d}, stage={s}\n", .{ id, stage });
    var stale = try openSessionWithId(alloc, id, "cdp-async-stale");
    var stale_live = true;
    errdefer if (stale_live) {
        std.debug.print("cdp stale frames:\n{s}\n", .{stale.got.items});
        stale.deinit();
    };
    try send(&stale, "Runtime.enable", "", 1);
    stage = "stale-response-1";
    try pumpResponse(&stale, 1);
    try send(&stale, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    stage = "stale-response-2";
    try pumpResponse(&stale, 2);
    const stale_eval = engine.evalScript(id, "function staleSchedule(){ Promise.resolve().then(function staleJob(){ console.log('stale-token'); }); } staleSchedule();", "stale-instance.js");
    if (stale_eval.result) |text| std.heap.c_allocator.free(text);
    if (stale_eval.err) |text| std.heap.c_allocator.free(text);
    stage = "stale-deinit";
    stale.deinit();
    stale_live = false;
    stage = "open-fresh";

    var fresh = try openSessionWithId(alloc, id, "cdp-async-fresh");
    defer fresh.deinit();
    errdefer std.debug.print("cdp fresh frames:\n{s}\n", .{fresh.got.items});
    try send(&fresh, "Runtime.enable", "", 1);
    stage = "fresh-response-1";
    try pumpResponse(&fresh, 1);
    try send(&fresh, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 2);
    stage = "fresh-response-2";
    try pumpResponse(&fresh, 2);
    const fresh_eval = engine.evalScript(id, "function freshSchedule(){ Promise.resolve().then(function freshJob(){ console.log('fresh-token'); }); } freshSchedule();", "fresh-instance.js");
    if (fresh_eval.result) |text| std.heap.c_allocator.free(text);
    if (fresh_eval.err) |text| std.heap.c_allocator.free(text);
    stage = "fresh-token";
    try pump(&fresh, "fresh-token");
    stage = "fresh-parent-assert";
    try testing.expect(std.mem.indexOf(u8, fresh.got.items, "\"functionName\":\"freshSchedule\"") != null);
    stage = "stale-parent-absent-assert";
    try testing.expect(std.mem.indexOf(u8, fresh.got.items, "staleSchedule") == null);
}

test "cdp: destroying an idle async instance resets depth before its id is reused" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    const id = helpers.nextInstanceId();

    var stale = try openSessionWithId(alloc, id, "cdp-async-idle-stale");
    try send(&stale, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 1);
    try pumpResponse(&stale, 1);
    // Do not queue a Promise, timer, or other job. Teardown must still clear the depth slot associated with this instance ID.
    stale.deinit();

    var fresh = try openSessionWithId(alloc, id, "cdp-async-idle-fresh");
    defer fresh.deinit();
    try send(&fresh, "Runtime.enable", "", 1);
    try pumpResponse(&fresh, 1);
    const fresh_eval = engine.evalScript(id, "function freshTimer(){ setTimeout(function tick(){ console.log('fresh-idle-token'); }, 0); } freshTimer();", "fresh-idle-instance.js");
    if (fresh_eval.result) |text| std.heap.c_allocator.free(text);
    if (fresh_eval.err) |text| std.heap.c_allocator.free(text);
    try pump(&fresh, "fresh-idle-token");
    try testing.expect(std.mem.indexOf(u8, fresh.got.items, "\"description\":\"setTimeout\"") == null);
    try testing.expect(std.mem.indexOf(u8, fresh.got.items, "\"functionName\":\"freshTimer\"") == null);
}

test "cdp: async depth two keeps a Promise parent through a timer" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-async-depth-two");
    defer session.deinit();
    try send(&session, "Runtime.enable", "", 1);
    try pumpResponse(&session, 1);
    try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":2}", 2);
    try pumpResponse(&session, 2);
    const source = "function rootSchedule(){ Promise.resolve().then(function promiseStep(){ setTimeout(function timerStep(){ console.log('depth-two-token'); }, 0); }); } rootSchedule();";
    const ran = engine.evalScript(session.id, source, "depth-two.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try pump(&session, "depth-two-token");
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"description\":\"setTimeout\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"description\":\"Promise\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"rootSchedule\"") != null);
}

test "cdp: Profiler.stop returns a sample of the running function" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-cpu-profile");
    defer session.deinit();
    try send(&session, "Profiler.enable", "", 1);
    try pumpResponse(&session, 1);
    try configureFastProfilerSampling(&session);
    try send(&session, "Profiler.start", "", 2);
    try pumpResponse(&session, 2);
    const src = "function spin(){ var i = 0; while (i < 2000000) i++; } spin();";
    const ran = engine.evalScript(session.id, src, "spin.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);
    try send(&session, "Profiler.stop", "", 3);
    try pumpResponse(&session, 3);
    try testing.expect(sample_hook.load() == null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"profile\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"spin\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"hitCount\":") != null);
}

fn profileSampleCount(payload: []const u8) !usize {
    const key = "\"samples\":[";
    const at = std.mem.indexOf(u8, payload, key) orelse return error.TestUnexpectedResult;
    const rest = payload[at + key.len ..];
    if (rest.len == 0 or rest[0] == ']') return 0;
    var count: usize = 1;
    for (rest) |byte| {
        if (byte == ']') break;
        if (byte == ',') count += 1;
    }
    return count;
}

fn maxHitCount(payload: []const u8) !u32 {
    const key = "\"hitCount\":";
    var rest = payload;
    var max: u32 = 0;
    var found = false;
    while (std.mem.indexOf(u8, rest, key)) |at| {
        found = true;
        rest = rest[at + key.len ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
        if (end == 0) return error.TestUnexpectedResult;
        const n = try std.fmt.parseInt(u32, rest[0..end], 10);
        if (n > max) max = n;
        rest = rest[end..];
    }
    if (!found) return error.TestUnexpectedResult;
    return max;
}

// Cross the actual sampling window before asserting that the public profile stays bounded. A fixed JavaScript iteration count can finish before the window fills in optimized builds.
test "cdp: Profiler.stop stays bounded after the sample ring fills" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    // Request a small explicit window. The production default is larger, but this test needs to cross the ring boundary deterministically.
    const reserved: usize = 64;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-cpu-profile-bound");
    defer session.deinit();
    try send(&session, "Profiler.enable", "", 1);
    try pumpResponse(&session, 1);
    try configureFastProfilerSampling(&session);
    try send(&session, "Profiler.start", "{\"maxSamples\":64}", 2);
    try pumpResponse(&session, 2);
    const src = "function spin(){ var i = 0; while (i < 4000000) i++; } spin();";
    const started = @import("zev").monotonicMilliseconds();
    while (profiler.TestCases.recordedSampleCount(session.id) <= reserved) {
        try helpers.evalOk(session.id, src);
        if (@import("zev").monotonicMilliseconds() - started > 5000) return error.ProfilerSampleTimeout;
    }
    try send(&session, "Profiler.stop", "", 3);
    try pumpResponse(&session, 3);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"spin\"") != null);
    const hits = try maxHitCount(session.got.items);
    try testing.expect(hits > 0);
    const n = try profileSampleCount(session.got.items);
    if (n != reserved) {
        std.debug.print("profile samples: {d}, reserved: {d}\n", .{ n, reserved });
        return error.TestExpectedEqual;
    }
}
