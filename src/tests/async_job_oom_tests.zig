//! A native Promise job remains runnable when Zig's optional async-parent metadata cannot be recorded. Its later phase-1 callback must not consume the following job's parent trace.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const inspector = @import("../inspector/root.zig");
const faults = @import("inspector_test_faults.zig");
const wire = @import("inspector_tests.zig");

fn sendAndPump(id: i32, stream: wire.TestStream, reader: *wire.FrameReader, received: *std.ArrayList(u8), message: []const u8, response_id: i64) !void {
    const start = received.items.len;
    try wire.writeMaskedText(stream, message);
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        _ = dispatch.tickInstance(id);
        engine.runEventLoopOnce(id);
        try wire.readTextFrames(testing.allocator, reader, received, 1);
        if (try wire.hasResponseIdSince(testing.allocator, received.items, start, response_id)) return;
    }
    return error.TestUnexpectedResult;
}

fn queuePromiseWithoutDrain(id: i32, source: [:0]const u8) !void {
    const ctx = engine.getContext(id) orelse return error.MissingContext;
    switch (backend.active_backend) {
        .quickjs => {
            const c = @import("../backend/quickjs/c_api.zig");
            const result = c.qjs.JS_Eval(ctx, source.ptr, source.len, "async-job-oom.js", c.qjs.JS_EVAL_TYPE_GLOBAL);
            defer c.jsbay_qjs_JS_FreeValue(ctx, result);
            try testing.expect(!c.jsIsException(result));
        },
        .quickjs_ng => {
            const c = @import("../backend/quickjs_ng/c_api.zig");
            const result = c.qjs.JS_Eval(ctx, source.ptr, source.len, "async-job-oom.js", c.qjs.JS_EVAL_TYPE_GLOBAL);
            defer c.jsbay_qjs_JS_FreeValue(ctx, result);
            try testing.expect(!c.jsIsException(result));
        },
        .jsc => unreachable,
    }
}

fn drainPromiseJobsAtTaskBoundary(id: i32) !void {
    const ctx = engine.getContext(id) orelse return error.MissingContext;
    @import("../runtime/js_scheduler.zig").checkpoint(id, ctx);
}

fn consoleEventForToken(payloads: []const u8, token: []const u8) ?[]const u8 {
    const token_at = std.mem.indexOf(u8, payloads, token) orelse return null;
    const event_start = std.mem.lastIndexOf(u8, payloads[0..token_at], "{\"method\":\"Runtime.consoleAPICalled\"") orelse return null;
    const event_end = std.mem.indexOfPos(u8, payloads, event_start, "}}}") orelse return null;
    return payloads[event_start .. event_end + 3];
}

test "cdp: Promise async parents stay aligned when one metadata enqueue runs out of memory" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    if (comptime !@import("build_options").inspector) return;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const handle = try inspector.start(id, .{ .port = 0, .target_id = "async-job-oom" });
    defer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    defer stream.close();
    try wire.doWsHandshake(testing.allocator, stream, "async-job-oom");
    var reader = wire.FrameReader.init(stream);
    defer reader.deinit(testing.allocator);
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(testing.allocator);

    try sendAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Runtime.enable\"}", 1);
    try sendAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 2);

    // The first Promise is accepted by QuickJS but has no Zig queue entry. The second must still retain its own scheduling parent, and the first must never inherit that later parent's stack.
    faults.arm(id, .async_job_metadata_enqueue);
    try queuePromiseWithoutDrain(id,
        \\function droppedParent(){ Promise.resolve().then(function firstJob(){ console.log('oom-first-token'); }); }
        \\function keptParent(){ Promise.resolve().then(function secondJob(){ console.log('oom-second-token'); }); }
        \\droppedParent(); keptParent();
    );
    try testing.expect(faults.wasConsumed(id, .async_job_metadata_enqueue));
    try drainPromiseJobsAtTaskBoundary(id);

    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        engine.runEventLoopOnce(id);
        try wire.readTextFrames(testing.allocator, &reader, &received, 1);
        if (std.mem.indexOf(u8, received.items, "oom-first-token") != null and std.mem.indexOf(u8, received.items, "oom-second-token") != null) break;
    }
    const first = consoleEventForToken(received.items, "oom-first-token") orelse return error.TestUnexpectedResult;
    const second = consoleEventForToken(received.items, "oom-second-token") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, first, "keptParent") == null);
    try testing.expect(std.mem.indexOf(u8, first, "\"description\":\"Promise\"") == null);
    try testing.expect(std.mem.indexOf(u8, second, "\"description\":\"Promise\"") != null);
    try testing.expect(std.mem.indexOf(u8, second, "keptParent") != null);
}
