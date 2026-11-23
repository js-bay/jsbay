const std = @import("std");

pub const SessionId = u64;
pub const EventKind = enum(u8) { session_opened, session_closed, message };
/// `payload` is borrowed and only valid until `EventHandler` returns.
pub const Event = struct { kind: EventKind, session_id: SessionId, payload: []const u8 };
pub const EventHandler = *const fn (ctx: ?*anyopaque, event: Event) void;
pub const DiscoveryTarget = struct { title: []const u8, kind: []const u8, url: []const u8, id: []const u8 };

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// Inspector attachment takes shutdown ownership before calling this, including on failure. `deinit` must quiesce callbacks before returning.
        start: *const fn (ctx: *anyopaque, event_ctx: ?*anyopaque, handler: EventHandler) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,
        /// Consume or copy `text` before returning.
        send_text: *const fn (ctx: *anyopaque, session: SessionId, text: []const u8) bool,
        /// Consume or copy `text` before returning.
        broadcast_text: *const fn (ctx: *anyopaque, text: []const u8) void,
        close_session: *const fn (ctx: *anyopaque, session: SessionId) void,
        set_discovery_target: ?*const fn (ctx: *anyopaque, target: DiscoveryTarget) void = null,
        bound_port: ?*const fn (ctx: *anyopaque) u16 = null,
        max_message_bytes: ?*const fn (ctx: *anyopaque) usize = null,
        max_backlog_bytes: ?*const fn (ctx: *anyopaque) usize = null,
        /// A nonzero token is returned to the delivery observer after the frame is written. Token zero does not request a delivery callback.
        send_text_tracked: ?*const fn (ctx: *anyopaque, session: SessionId, text: []const u8, token: u64) bool = null,
        /// Setting the observer to null waits for a running callback to return, except when called by that callback itself.
        set_delivery_observer: ?*const fn (ctx: *anyopaque, observer_ctx: ?*anyopaque, observer: ?*const fn (?*anyopaque, SessionId, u64) void) void = null,
    };
    pub fn start(self: *Transport, event_ctx: ?*anyopaque, handler: EventHandler) !void {
        return self.vtable.start(self.ctx, event_ctx, handler);
    }
    pub fn deinit(self: *Transport) void {
        self.vtable.deinit(self.ctx);
    }
    pub fn sendText(self: *Transport, session: SessionId, text: []const u8) bool {
        return self.vtable.send_text(self.ctx, session, text);
    }
    pub fn sendTrackedText(self: *Transport, session: SessionId, text: []const u8, token: u64) bool {
        if (token != 0 and self.supportsTrackedDelivery()) {
            return self.vtable.send_text_tracked.?(self.ctx, session, text, token);
        }
        return self.sendText(session, text);
    }
    pub fn supportsTrackedDelivery(self: *Transport) bool {
        return self.vtable.send_text_tracked != null and self.vtable.set_delivery_observer != null;
    }
    pub fn broadcastText(self: *Transport, text: []const u8) void {
        self.vtable.broadcast_text(self.ctx, text);
    }
    pub fn closeSession(self: *Transport, session: SessionId) void {
        self.vtable.close_session(self.ctx, session);
    }
    pub fn setDiscoveryTarget(self: *Transport, target: DiscoveryTarget) void {
        if (self.vtable.set_discovery_target) |f| f(self.ctx, target);
    }
    pub fn boundPort(self: *Transport) u16 {
        return if (self.vtable.bound_port) |f| f(self.ctx) else 0;
    }
    pub const default_max_message_bytes: usize = 64 * 1024 * 1024;
    pub fn maxMessageBytes(self: *Transport) usize {
        return if (self.vtable.max_message_bytes) |f| f(self.ctx) else default_max_message_bytes;
    }
    pub const default_max_backlog_bytes: usize = 8 * 1024 * 1024;
    pub fn maxBacklogBytes(self: *Transport) usize {
        return if (self.vtable.max_backlog_bytes) |f| f(self.ctx) else default_max_backlog_bytes;
    }
    pub fn setDeliveryObserver(self: *Transport, observer_ctx: ?*anyopaque, observer: ?*const fn (?*anyopaque, SessionId, u64) void) void {
        if (self.vtable.set_delivery_observer) |f| f(self.ctx, observer_ctx, observer);
    }
};
