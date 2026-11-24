const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const helpers = @import("test_helpers.zig");
const options = @import("build_options");

const fixture = @import("host_transport_fixture.zig");
const HostTransport = fixture.HostTransport;

fn waitForReply(host: *HostTransport, instance_id: i32, session: inspector.SessionId, request_id: i64) !std.json.Parsed(std.json.Value) {
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        engine.runEventLoopOnce(instance_id);
        const reply = host.reply(session, request_id) catch |err| switch (err) {
            error.MissingReply => continue,
            else => return err,
        };
        return reply;
    }
    return error.MissingReply;
}

fn expectErrorReply(reply: *const std.json.Parsed(std.json.Value)) !void {
    try testing.expect(reply.value.object.get("result") == null);
    try testing.expect(reply.value.object.get("error") != null);
}

fn enableRuntime(host: *HostTransport) !void {
    host.emit(.session_opened, 7, "");
    host.emit(.message, 7, "{\"id\":70,\"method\":\"Runtime.enable\"}");
    var enabled = try host.reply(7, 70);
    defer enabled.deinit();
    try testing.expect(enabled.value.object.get("result") != null);
}

fn expectStopped(host: *HostTransport, method: []const u8) !void {
    try testing.expect(host.hasMethod(method));
    try testing.expect(host.stop_on_method == null);
    try testing.expectEqual(@as(usize, 1), host.deinit_count);
    try testing.expect(host.handler == null);
}

const Enabled = if (options.inspector) struct {
    test "host transport evaluates CDP without sockets and copies borrowed input" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{};
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer inspector.stop(handle);
        host.emit(.session_opened, 7, "");
        host.emit(.session_opened, 8, "");
        host.emit(.message, 7, "{\"id\":1,\"method\":\"Runtime.enable\"}");
        var enabled = try host.reply(7, 1);
        defer enabled.deinit();
        try testing.expect(enabled.value.object.get("result") != null);

        var request = "{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"21 * 2\",\"returnByValue\":true}}".*;
        host.emit(.message, 7, &request);
        @memset(&request, 0xcc);
        engine.runEventLoopOnce(id);
        var evaluated = try host.reply(7, 2);
        defer evaluated.deinit();
        const value = evaluated.value.object.get("result").?.object.get("result").?.object.get("value").?;
        switch (value) {
            .integer => |n| try testing.expectEqual(@as(i64, 42), n),
            .float => |n| try testing.expectEqual(@as(f64, 42), n),
            else => return error.WrongEvaluationResult,
        }
        try testing.expectError(error.MissingReply, host.reply(8, 2));

        host.emit(.session_closed, 7, "");
        host.emit(.message, 8, "{\"id\":3,\"method\":\"Runtime.enable\"}");
        var other = try host.reply(8, 3);
        defer other.deinit();
        try testing.expect(other.value.object.get("result") != null);
        inspector.stop(handle);
        try testing.expectEqual(@as(usize, 1), host.deinit_count);
        try testing.expect(host.handler == null);
    }

    test "host transport rejects failed heap snapshot events without false completion and retries" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend) or !options.heap_snapshot) return error.SkipZigTest;
        inline for ([_][]const u8{ "HeapProfiler.reportHeapSnapshotProgress", "HeapProfiler.addHeapSnapshotChunk" }) |rejected_method| {
            const id = helpers.nextInstanceId();
            try testing.expect(engine.create(id, .{}));
            defer engine.destroy(id);
            var host = HostTransport{};
            host.init();
            defer host.freeFrames();
            const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
            defer if (host.handler != null) inspector.stop(handle);
            host.emit(.session_opened, 7, "");

            host.fail_on_method = rejected_method;
            host.emit(.message, 7, "{\"id\":81,\"method\":\"HeapProfiler.takeHeapSnapshot\",\"params\":{\"reportProgress\":true}}");
            var rejected = try waitForReply(&host, id, 7, 81);
            defer rejected.deinit();
            try expectErrorReply(&rejected);
            try testing.expect(!host.hasMethod(rejected_method));

            const retry_start = host.frames.items.len;
            host.emit(.message, 7, "{\"id\":82,\"method\":\"HeapProfiler.takeHeapSnapshot\",\"params\":{\"reportProgress\":false}}");
            var retried = try waitForReply(&host, id, 7, 82);
            defer retried.deinit();
            try testing.expect(retried.value.object.get("error") == null);
            try testing.expect(retried.value.object.get("result") != null);
            try testing.expect(host.hasMethodSince(retry_start, "HeapProfiler.addHeapSnapshotChunk"));
            try testing.expect(!host.hasMethodSince(retry_start, "HeapProfiler.reportHeapSnapshotProgress"));
        }
    }

    test "host transport can stop synchronously while heap snapshot progress is sent" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend) or !options.heap_snapshot) return error.SkipZigTest;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        host.stop_on_send = handle;
        host.stop_on_method = "HeapProfiler.reportHeapSnapshotProgress";
        host.emit(.session_opened, 7, "");
        host.emit(.message, 7, "{\"id\":83,\"method\":\"HeapProfiler.takeHeapSnapshot\",\"params\":{\"reportProgress\":true}}");
        engine.runEventLoopOnce(id);
        try expectStopped(&host, "HeapProfiler.reportHeapSnapshotProgress");
    }

    test "host transport partial startup closes callbacks exactly once" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .fail_start = true, .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        try testing.expectError(error.TransportStartFailed, inspector.startWithTransport(id, &host.endpoint, .{}));
        try testing.expectEqual(@as(usize, 1), host.deinit_count);
        try testing.expect(!host.observer_present_at_deinit);
        try testing.expect(host.handler == null);
        // A failed attach leaves the same instance available for a new attach.
        host.fail_start = false;
        host.init();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        try testing.expect(host.delivery_observer_registered);
        inspector.stop(handle);
        try testing.expectEqual(@as(usize, 2), host.deinit_count);
        try testing.expect(!host.observer_present_at_deinit);
    }

    test "host transport delivery observer lifecycle and completion dispatch" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{};
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        try testing.expect(host.delivery_observer_registered);
        try testing.expect(host.delivery_observer != null);

        // Dispatches tracked completion cleanly while inspector session is active.
        host.delivery_observer.?(host.delivery_observer_ctx, 7, 41);

        inspector.stop(handle);
        try testing.expect(!host.delivery_observer_registered);
        try testing.expect(!host.observer_present_at_deinit);
    }

    test "host transport can stop synchronously from an owner-thread send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        host.stop_on_send = handle;
        host.emit(.session_opened, 7, "");
        host.emit(.message, 7, "{\"id\":4,\"method\":\"Runtime.enable\"}");
        try testing.expectEqual(@as(usize, 1), host.deinit_count);
        try testing.expect(host.handler == null);
    }

    test "host transport can stop synchronously from a foreign-thread send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        host.stop_on_send = handle;
        host.emit(.session_opened, 7, "");
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(transport: *HostTransport) void {
                transport.emit(.message, 7, "{\"id\":5,\"method\":\"Runtime.enable\"}");
            }
        }.run, .{&host});
        thread.join();
        try testing.expect(!host.observer_present_at_deinit);
        engine.runEventLoopOnce(id);
        try testing.expectEqual(@as(usize, 1), host.deinit_count);
        try testing.expect(host.handler == null);
    }

    test "host transport can stop synchronously from a console send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        try enableRuntime(&host);

        host.stop_on_send = handle;
        host.stop_on_method = "Runtime.consoleAPICalled";
        const evaluated = engine.evalScript(id, "console.log('host-stop-console')", "host-stop-console.js");
        defer helpers.freeEvalResult(evaluated);
        try testing.expect(evaluated.err == null);
        try expectStopped(&host, "Runtime.consoleAPICalled");
    }

    test "host transport can stop synchronously from an uncaught exception send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        try enableRuntime(&host);
        host.stop_on_send = handle;
        host.stop_on_method = "Runtime.exceptionThrown";
        const evaluated = engine.evalScript(id, "throw new Error('host-stop-uncaught')", "host-stop-uncaught.js");
        defer helpers.freeEvalResult(evaluated);
        try testing.expect(evaluated.err != null);
        try expectStopped(&host, "Runtime.exceptionThrown");
    }

    test "host transport can stop synchronously from a typed exception send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        try enableRuntime(&host);
        host.stop_on_send = handle;
        host.stop_on_method = "Runtime.exceptionThrown";
        const evaluated = engine.evalScriptTyped(id, "throw new Error('host-stop-typed')", "host-stop-typed.js") orelse return error.TypedEvaluationUnavailable;
        const ctx = engine.getContext(id) orelse return error.MissingContext;
        defer if (evaluated.value) |value| backend.ActiveEngine.freeValue(ctx, value);
        defer if (evaluated.exception) |exception| backend.ActiveEngine.freeValue(ctx, exception);
        try testing.expect(evaluated.exception != null);
        try expectStopped(&host, "Runtime.exceptionThrown");
    }
} else struct {
    test "host transport is released when Inspector is disabled" {
        var host = HostTransport{};
        host.init();
        defer host.freeFrames();
        try testing.expectError(error.UnsupportedFeature, inspector.startWithTransport(0, &host.endpoint, .{}));
        try testing.expectEqual(@as(usize, 1), host.deinit_count);
    }
};

const DisabledNetwork = if (options.inspector and !options.inspector_transport) struct {
    test "host transport remains available when the bundled server is disabled" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        try testing.expectError(error.UnsupportedFeature, inspector.start(id, .{ .port = 0 }));
        var host = HostTransport{};
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        inspector.stop(handle);
        try testing.expectEqual(@as(usize, 1), host.deinit_count);
    }
} else struct {};

const QuickJsStopCallbacks = if (options.inspector and backend.isQuickJsApiBackend(backend.active_backend)) struct {
    test "host transport can stop synchronously from a rejection send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        try enableRuntime(&host);
        host.stop_on_send = handle;
        host.stop_on_method = "Runtime.exceptionThrown";
        const evaluated = engine.evalScript(id, "Promise.reject(new Error('host-stop-rejection'))", "host-stop-rejection.js");
        defer helpers.freeEvalResult(evaluated);
        try testing.expect(evaluated.err == null);
        try expectStopped(&host, "Runtime.exceptionThrown");
    }
} else struct {};

const QuickJsNgStopCallbacks = if (options.inspector and backend.active_backend == .quickjs_ng) struct {
    test "host transport can stop synchronously from a script parsed send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        try enableRuntime(&host);
        host.emit(.message, 7, "{\"id\":71,\"method\":\"Debugger.enable\"}");
        engine.runEventLoopOnce(id);
        var enabled = try host.reply(7, 71);
        defer enabled.deinit();
        try testing.expect(enabled.value.object.get("result") != null);
        host.stop_on_send = handle;
        host.stop_on_method = "Debugger.scriptParsed";
        const evaluated = engine.evalScript(id, "var hostStopScriptParsed = 1", "host-stop-script-parsed.js");
        defer helpers.freeEvalResult(evaluated);
        try testing.expect(evaluated.err == null);
        try expectStopped(&host, "Debugger.scriptParsed");
    }

    test "host transport can stop synchronously from a debugger paused send callback" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        defer if (host.handler != null) inspector.stop(handle);
        try enableRuntime(&host);
        host.emit(.message, 7, "{\"id\":72,\"method\":\"Debugger.enable\"}");
        engine.runEventLoopOnce(id);
        var enabled = try host.reply(7, 72);
        defer enabled.deinit();
        try testing.expect(enabled.value.object.get("result") != null);

        const primed = engine.evalScript(id, "var hostStopPausedPrimed = 1", "host-stop-paused-primed.js");
        defer helpers.freeEvalResult(primed);
        try testing.expect(primed.err == null);
        host.emit(.message, 7, "{\"id\":73,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"host-stop-paused.js\",\"lineNumber\":2}}");
        engine.runEventLoopOnce(id);
        var breakpoint = try host.reply(7, 73);
        defer breakpoint.deinit();
        try testing.expect(breakpoint.value.object.get("result") != null);
        host.stop_on_send = handle;
        host.stop_on_method = "Debugger.paused";
        const Eval = struct {
            fn run(instance_id: i32) void {
                const evaluated = engine.evalScript(instance_id, "function hostStopPaused() {\n  var n = 1;\n  return n;\n}\nhostStopPaused();", "host-stop-paused.js");
                helpers.freeEvalResult(evaluated);
            }
        };
        const thread = try std.Thread.spawn(.{}, Eval.run, .{id});
        thread.join();
        try expectStopped(&host, "Debugger.paused");
    }
} else struct {};

comptime {
    _ = Enabled;
    _ = DisabledNetwork;
    _ = QuickJsStopCallbacks;
    _ = QuickJsNgStopCallbacks;
}
