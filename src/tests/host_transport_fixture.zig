const std = @import("std");
const testing = std.testing;
const inspector = @import("../inspector/root.zig");

pub const Frame = struct { session: inspector.SessionId, text: []u8 };

pub const HostTransport = struct {
    endpoint: inspector.Transport = undefined,
    handler: ?inspector.EventHandler = null,
    handler_ctx: ?*anyopaque = null,
    frames: std.ArrayList(Frame) = .empty,
    deinit_count: usize = 0,
    delivery_observer: ?*const fn (?*anyopaque, inspector.SessionId, u64) void = null,
    delivery_observer_ctx: ?*anyopaque = null,
    delivery_observer_registered: bool = false,
    observer_present_at_deinit: bool = false,
    fail_start: bool = false,
    close_during_deinit: bool = false,
    stop_on_send: ?*inspector.Handle = null,
    stop_on_method: ?[]const u8 = null,
    reenter_message_on_method: ?[]const u8 = null,
    reenter_message_payload: ?[]const u8 = null,
    fail_on_method: ?[]const u8 = null,

    const vtable: inspector.Transport.VTable = .{
        .start = start,
        .deinit = deinit,
        .send_text = send,
        .broadcast_text = broadcast,
        .close_session = closeSession,
        .set_delivery_observer = setDeliveryObserver,
    };

    pub fn init(self: *HostTransport) void {
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

    fn setDeliveryObserver(ctx: *anyopaque, observer_ctx: ?*anyopaque, observer: ?*const fn (?*anyopaque, inspector.SessionId, u64) void) void {
        const self = from(ctx);
        self.delivery_observer_ctx = observer_ctx;
        self.delivery_observer = observer;
        self.delivery_observer_registered = observer != null;
    }

    fn deinit(ctx: *anyopaque) void {
        const self = from(ctx);
        self.deinit_count += 1;
        self.observer_present_at_deinit = self.delivery_observer_registered;
        // A transport may finish an already admitted callback while closing.
        if (self.close_during_deinit) self.emit(.session_closed, 7, "");
        self.handler = null;
        self.handler_ctx = null;
    }

    fn send(ctx: *anyopaque, session: inspector.SessionId, text: []const u8) bool {
        const self = from(ctx);
        if (self.fail_on_method) |method| {
            if (messageHasMethod(text, method)) {
                self.fail_on_method = null;
                return false;
            }
        }
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
        if (self.reenter_message_on_method) |method| {
            if (messageHasMethod(text, method)) {
                self.reenter_message_on_method = null;
                const payload = self.reenter_message_payload orelse return true;
                self.emit(.message, session, payload);
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

    pub fn emit(self: *HostTransport, kind: inspector.EventKind, session: inspector.SessionId, payload: []const u8) void {
        if (self.handler) |handler| handler(self.handler_ctx, .{ .kind = kind, .session_id = session, .payload = payload });
    }

    pub fn freeFrames(self: *HostTransport) void {
        for (self.frames.items) |frame| testing.allocator.free(frame.text);
        self.frames.deinit(testing.allocator);
    }

    pub fn reply(self: *HostTransport, session: inspector.SessionId, id: i64) !std.json.Parsed(std.json.Value) {
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

    pub fn hasMethod(self: *const HostTransport, method: []const u8) bool {
        for (self.frames.items) |frame| {
            var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, frame.text, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const value = parsed.value.object.get("method") orelse continue;
            if (value == .string and std.mem.eql(u8, value.string, method)) return true;
        }
        return false;
    }

    pub fn hasMethodSince(self: *const HostTransport, frame_start: usize, method: []const u8) bool {
        for (self.frames.items[frame_start..]) |frame| {
            var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, frame.text, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const value = parsed.value.object.get("method") orelse continue;
            if (value == .string and std.mem.eql(u8, value.string, method)) return true;
        }
        return false;
    }
};

fn messageHasMethod(text: []const u8, method: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const value = parsed.value.object.get("method") orelse return false;
    return value == .string and std.mem.eql(u8, value.string, method);
}
