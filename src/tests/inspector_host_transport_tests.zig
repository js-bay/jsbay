const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const helpers = @import("test_helpers.zig");
const options = @import("build_options");

const Frame = struct { session: inspector.SessionId, text: []u8 };

const HostTransport = struct {
    endpoint: inspector.Transport = undefined,
    handler: ?inspector.EventHandler = null,
    handler_ctx: ?*anyopaque = null,
    frames: std.ArrayList(Frame) = .empty,
    deinit_count: usize = 0,
    fail_start: bool = false,
    close_during_deinit: bool = false,
    stop_on_send: ?*inspector.Handle = null,
    stop_on_method: ?[]const u8 = null,

    const vtable: inspector.Transport.VTable = .{
        .start = start,
        .deinit = deinit,
        .send_text = send,
        .broadcast_text = broadcast,
        .close_session = closeSession,
    };

    fn init(self: *HostTransport) void {
        self.endpoint = .{ .ctx = self, .vtable = &vtable };
    }

    fn from(ctx: *anyopaque) *HostTransport {
        return @ptrCast(@alignCast(ctx));
    }

    fn start(ctx: *anyopaque, handler_ctx: ?*anyopaque, handler: inspector.EventHandler) !void {
        const self = from(ctx);
        self.handler_ctx = handler_ctx;
        self.handler = handler;
        if (self.fail_start) {
            self.emit(.session_opened, 7, "");
            return error.PartialStart;
        }
    }

    fn deinit(ctx: *anyopaque) void {
        const self = from(ctx);
        self.deinit_count += 1;
        // A transport may finish an already admitted callback while closing.
        if (self.close_during_deinit) self.emit(.session_closed, 7, "");
        self.handler = null;
        self.handler_ctx = null;
    }

    fn send(ctx: *anyopaque, session: inspector.SessionId, text: []const u8) bool {
        const self = from(ctx);
        const copy = testing.allocator.dupe(u8, text) catch return false;
        self.frames.append(testing.allocator, .{ .session = session, .text = copy }) catch {
            testing.allocator.free(copy);
            return false;
        };
        if (self.stop_on_method) |method| {
            var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{}) catch return true;
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("method")) |value| {
                    if (value == .string and std.mem.eql(u8, value.string, method)) {
                        self.stop_on_method = null;
                        const handle = self.stop_on_send orelse return true;
                        self.stop_on_send = null;
                        inspector.stop(handle);
                        return true;
                    }
                }
            }
        }
        if (self.stop_on_send) |handle| {
            if (self.stop_on_method != null) return true;
            self.stop_on_send = null;
            inspector.stop(handle);
        }
        return true;
    }

    fn broadcast(ctx: *anyopaque, text: []const u8) void {
        _ = send(ctx, 0, text);
    }

    fn closeSession(ctx: *anyopaque, session: inspector.SessionId) void {
        from(ctx).emit(.session_closed, session, "");
    }

    fn emit(self: *HostTransport, kind: inspector.EventKind, session: inspector.SessionId, payload: []const u8) void {
        if (self.handler) |handler| handler(self.handler_ctx, .{ .kind = kind, .session_id = session, .payload = payload });
    }

    fn freeFrames(self: *HostTransport) void {
        for (self.frames.items) |frame| testing.allocator.free(frame.text);
        self.frames.deinit(testing.allocator);
    }

    fn reply(self: *HostTransport, session: inspector.SessionId, id: i64) !std.json.Parsed(std.json.Value) {
        for (self.frames.items) |frame| {
            if (frame.session != session) continue;
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame.text, .{});
            if (parsed.value.object.get("id")) |value| {
                if (value == .integer and value.integer == id) return parsed;
            }
            parsed.deinit();
        }
        return error.MissingReply;
    }

    fn hasMethod(self: *const HostTransport, method: []const u8) bool {
        for (self.frames.items) |frame| {
            var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, frame.text, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const value = parsed.value.object.get("method") orelse continue;
            if (value == .string and std.mem.eql(u8, value.string, method)) return true;
        }
        return false;
    }
};

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

    test "host transport partial startup closes callbacks exactly once" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var host = HostTransport{ .fail_start = true, .close_during_deinit = true };
        host.init();
        defer host.freeFrames();
        try testing.expectError(error.TransportStartFailed, inspector.startWithTransport(id, &host.endpoint, .{}));
        try testing.expectEqual(@as(usize, 1), host.deinit_count);
        try testing.expect(host.handler == null);
        // A failed attach leaves the same instance available for a new attach.
        host.fail_start = false;
        host.init();
        const handle = try inspector.startWithTransport(id, &host.endpoint, .{});
        inspector.stop(handle);
        try testing.expectEqual(@as(usize, 2), host.deinit_count);
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
