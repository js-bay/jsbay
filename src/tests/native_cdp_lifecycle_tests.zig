const std = @import("std");
const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const helpers = @import("test_helpers.zig");

const Host = struct {
    handler: ?inspector.EventHandler = null,
    handler_ctx: ?*anyopaque = null,
    handle: ?*inspector.Handle = null,
    stop_marker: []const u8,
    stop_returned: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(usize) = .init(0),
    rejected: std.atomic.Value(bool) = .init(false),
    response_5: std.atomic.Value(bool) = .init(false),
    closed_sessions: std.atomic.Value(usize) = .init(0),
    block_send: std.atomic.Value(bool) = .init(false),
    send_started: std.atomic.Value(bool) = .init(false),
    release_send: std.atomic.Value(bool) = .init(false),
    report_session_closed: bool = true,

    const vtable: inspector.Transport.VTable = .{
        .start = start,
        .deinit = deinit,
        .send_text = send,
        .broadcast_text = broadcast,
        .close_session = closeSession,
    };

    fn start(raw: *anyopaque, ctx: ?*anyopaque, handler: inspector.EventHandler) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.handler = handler;
        self.handler_ctx = ctx;
    }

    fn deinit(raw: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        self.handler = null;
        _ = self.closed.fetchAdd(1, .seq_cst);
    }

    fn send(raw: *anyopaque, _: inspector.SessionId, text: []const u8) bool {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (std.mem.indexOf(u8, text, "\"id\":42") != null and std.mem.indexOf(u8, text, "\"error\"") != null) self.rejected.store(true, .seq_cst);
        if (std.mem.indexOf(u8, text, "\"id\":5") != null) self.response_5.store(true, .seq_cst);
        if (self.block_send.load(.seq_cst)) {
            self.send_started.store(true, .seq_cst);
            while (!self.release_send.load(.seq_cst)) std.Thread.yield() catch {};
        }
        if (std.mem.indexOf(u8, text, self.stop_marker) != null) {
            if (self.handle) |handle| {
                self.handle = null;
                inspector.stop(handle);
                self.stop_returned.store(true, .seq_cst);
            }
        }
        return true;
    }

    fn broadcast(raw: *anyopaque, text: []const u8) void {
        _ = send(raw, 0, text);
    }

    fn closeSession(raw: *anyopaque, session_id: inspector.SessionId) void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.report_session_closed) self.handler.?(self.handler_ctx, .{ .kind = .session_closed, .session_id = session_id, .payload = "" });
        _ = self.closed_sessions.fetchAdd(1, .seq_cst);
    }

    fn emit(self: *Host, kind: inspector.EventKind, text: []const u8) void {
        self.handler.?(self.handler_ctx, .{ .kind = kind, .session_id = 1, .payload = text });
    }
};

fn waitForResponseOrClose(id: i32, host: *Host) bool {
    for (0..100_000) |_| {
        engine.runEventLoopOnce(id);
        if (host.response_5.load(.seq_cst) or host.closed_sessions.load(.seq_cst) != 0) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

fn waitForSendStart(id: i32, host: *Host) bool {
    for (0..100_000) |_| {
        engine.runEventLoopOnce(id);
        if (host.send_started.load(.seq_cst)) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

fn waitForClose(id: i32, host: *Host) bool {
    for (0..100_000) |_| {
        engine.runEventLoopOnce(id);
        if (host.closed_sessions.load(.seq_cst) != 0) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

fn waitForCloseCount(id: i32, host: *Host, count: usize) bool {
    for (0..100_000) |_| {
        engine.runEventLoopOnce(id);
        if (host.closed_sessions.load(.seq_cst) >= count) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

fn stopDuringNativeSend(marker: []const u8, enable: ?[]const u8, expression: []const u8) !void {
    const id = helpers.nextInstanceId();
    try std.testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var host = Host{ .stop_marker = marker };
    var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
    const handle = try inspector.startWithTransport(id, &transport, .{});
    defer if (host.closed.load(.seq_cst) == 0) inspector.stop(handle);
    host.handle = handle;
    host.emit(.session_opened, "");
    if (enable) |command| host.emit(.message, command);
    const command = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{{\"expression\":\"{s}\"}}}}", .{expression});
    defer std.testing.allocator.free(command);
    host.emit(.message, command);
    for (0..100_000) |_| {
        engine.runEventLoopOnce(id);
        if (host.stop_returned.load(.seq_cst) and host.closed.load(.seq_cst) != 0) break;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(host.stop_returned.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), host.closed.load(.seq_cst));
}

comptime {
    if (backend.active_backend == .hermes and @import("build_options").inspector) {
        _ = struct {
            test "native CDP rejection does not fall through to generic Runtime" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "" };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                const state: *inspector.state.InspectorState = @ptrCast(@alignCast(handle));
                backend.ActiveEngineModule.c_api.hermes_inspector_close_sessions(@ptrCast(state.native_debugger));
                host.emit(.message, "{\"id\":42,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"globalThis.__nativeRoutingLeak = true\"}}");
                engine.runEventLoopOnce(id);
                try std.testing.expect(host.rejected.load(.seq_cst));
                try helpers.evalOk(id, "if (globalThis.__nativeRoutingLeak) throw new Error('Rejected native command executed');");
            }

            test "native CDP delivers or closes an oversized reply" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "" };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                host.emit(.message, "{\"id\":5,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"'x'.repeat(1100000)\"}}");
                try std.testing.expect(waitForResponseOrClose(id, &host));
            }

            test "native CDP closes a session when its owner task cannot be admitted" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "" };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                for (0..16) |_| engine.runEventLoopOnce(id);
                dispatch.failNextQueueAllocationForTesting();
                host.emit(.message, "{\"id\":5,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"6 * 7\"}}");
                try std.testing.expect(waitForResponseOrClose(id, &host));
                try std.testing.expectEqual(@as(usize, 1), host.closed_sessions.load(.seq_cst));
            }

            test "native CDP delivers a second terminal close after session reopen" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "" };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                for (0..16) |_| engine.runEventLoopOnce(id);
                dispatch.failNextQueueAllocationForTesting();
                host.emit(.message, "{\"id\":3,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1\"}}");
                try std.testing.expect(waitForCloseCount(id, &host, 1));
                host.emit(.session_opened, "");
                for (0..16) |_| engine.runEventLoopOnce(id);
                dispatch.failNextQueueAllocationForTesting();
                host.emit(.message, "{\"id\":4,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"2\"}}");
                try std.testing.expect(waitForCloseCount(id, &host, 2));
            }

            test "native CDP rejects commands while transport closure is pending" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "", .report_session_closed = false };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                for (0..16) |_| engine.runEventLoopOnce(id);
                dispatch.failNextQueueAllocationForTesting();
                host.emit(.message, "{\"id\":5,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"6 * 7\"}}");
                try std.testing.expect(waitForClose(id, &host));
                host.emit(.message, "{\"id\":6,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"globalThis.__nativeTerminalLeak = true\"}}");
                for (0..16) |_| engine.runEventLoopOnce(id);
                try helpers.evalOk(id, "if (globalThis.__nativeTerminalLeak) throw new Error('terminal-session command executed');");
            }

            test "native CDP closes a reply exceeding its byte budget" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "" };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                host.emit(.message, "{\"id\":5,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"'x'.repeat(4400000)\"}}");
                try std.testing.expect(waitForClose(id, &host));
                try std.testing.expectEqual(@as(usize, 1), host.closed_sessions.load(.seq_cst));
                try std.testing.expect(!host.response_5.load(.seq_cst));
            }

            test "native CDP closes an overloaded blocked outbound session" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "" };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                host.block_send.store(true, .seq_cst);
                defer host.release_send.store(true, .seq_cst);
                host.emit(.message, "{\"id\":1,\"method\":\"Runtime.enable\"}");
                try std.testing.expect(waitForSendStart(id, &host));
                host.emit(.message, "{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"for (let i = 0; i < 300; i++) console.log(i)\"}}");
                for (0..128) |_| engine.runEventLoopOnce(id);
                host.release_send.store(true, .seq_cst);
                try std.testing.expect(waitForClose(id, &host));
            }

            test "native CDP teardown never runs a cancelled all-queue command" {
                const id = helpers.nextInstanceId();
                try std.testing.expect(engine.create(id, .{}));
                defer engine.destroy(id);
                var host = Host{ .stop_marker = "" };
                var transport = inspector.Transport{ .ctx = &host, .vtable = &Host.vtable };
                const handle = try inspector.startWithTransport(id, &transport, .{});
                defer inspector.stop(handle);
                host.emit(.session_opened, "");
                host.emit(.message, "{\"id\":1,\"method\":\"Runtime.enable\"}");
                for (0..16) |_| engine.runEventLoopOnce(id);
                const command = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":2,\"method\":\"Runtime.callFunctionOn\",\"params\":{{\"executionContextId\":{d},\"functionDeclaration\":\"function() {{ globalThis.__nativeTeardownLeak = true; }}\"}}}}", .{id});
                defer std.testing.allocator.free(command);
                host.emit(.message, command);
                inspector.stop(handle);
                try helpers.evalOk(id, "if (globalThis.__nativeTeardownLeak) throw new Error('closed-session CDP command ran during teardown');");
            }

            test "native CDP host can synchronously stop from a reply" {
                try stopDuringNativeSend("\"id\":2", null, "6 * 7");
            }

            test "native CDP host can synchronously stop from console delivery" {
                try stopDuringNativeSend("Runtime.consoleAPICalled", "{\"id\":1,\"method\":\"Runtime.enable\"}", "console.log(42)");
            }

            test "native CDP host can synchronously stop from a paused event" {
                try stopDuringNativeSend("Debugger.paused", "{\"id\":1,\"method\":\"Debugger.enable\"}", "debugger; 42");
            }
        };
    }
}
