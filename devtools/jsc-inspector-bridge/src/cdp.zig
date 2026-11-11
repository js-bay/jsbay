//! CDP to WebKit Inspector Relay translation. One relay connection carries a single registered frontend sender, so the bridge owns the sender identity for the target: every CDP session reuses it, command ids are rewritten to unique relay ids so each reply reaches the session that issued it, and relay notifications are copied to every attached session.

const std = @import("std");
const wir = @import("wir.zig");
const plist = @import("plist.zig");
const transport = @import("inspector_transport");
const zev = @import("zev");

const Allocator = std.mem.Allocator;

/// True when `data` is a relay reply for `id`. The parsed id is compared because the probe's command id also prefixes other ids such as 10 or 1000000.
pub fn isReplyTo(allocator: Allocator, data: []const u8, id: i64) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const raw = parsed.value.object.get("id") orelse return false;
    return raw == .integer and raw.integer == id;
}

/// Reports a message the bridge discarded. Every dropped message is a debugging dead end, so `--trace` shows the reason.
fn logDrop(reason: []const u8) void {
    if (wir.trace_enabled) std.debug.print("[drop] {s}\n", .{reason});
}

/// The relay operations the bridge performs. Production uses `wir.Client`; tests script the replies so the translation layer runs without a simulator.
pub const Relay = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        connectFrontend: *const fn (ctx: *anyopaque, target: *const wir.Target) void,
        sendDidClose: *const fn (ctx: *anyopaque, target: *const wir.Target) void,
        sendData: *const fn (ctx: *anyopaque, target: *const wir.Target, json: []const u8) void,
        isClosed: *const fn (ctx: *anyopaque) bool,
        /// Next `_rpc_applicationSentData` payload, owned by the caller, or null when the timeout expires.
        nextData: *const fn (ctx: *anyopaque, timeout_ms: u64, allocator: Allocator) anyerror!?[]u8,
    };

    pub fn connectFrontend(self: Relay, target: *const wir.Target) void {
        self.vtable.connectFrontend(self.ctx, target);
    }

    pub fn sendDidClose(self: Relay, target: *const wir.Target) void {
        self.vtable.sendDidClose(self.ctx, target);
    }

    pub fn sendData(self: Relay, target: *const wir.Target, json: []const u8) void {
        self.vtable.sendData(self.ctx, target, json);
    }

    pub fn isClosed(self: Relay) bool {
        return self.vtable.isClosed(self.ctx);
    }

    pub fn nextData(self: Relay, timeout_ms: u64, allocator: Allocator) anyerror!?[]u8 {
        return self.vtable.nextData(self.ctx, timeout_ms, allocator);
    }
};

/// The CDP side of the bridge. Production uses the loopback transport; tests record the messages instead.
pub const Frontend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        sendText: *const fn (ctx: *anyopaque, session: transport.SessionId, text: []const u8) bool,
        closeSession: *const fn (ctx: *anyopaque, session: transport.SessionId) void,
        boundPort: *const fn (ctx: *anyopaque) u16,
    };

    pub fn sendText(self: Frontend, session: transport.SessionId, text: []const u8) bool {
        return self.vtable.sendText(self.ctx, session, text);
    }

    pub fn closeSession(self: Frontend, session: transport.SessionId) void {
        self.vtable.closeSession(self.ctx, session);
    }

    pub fn boundPort(self: Frontend) u16 {
        return self.vtable.boundPort(self.ctx);
    }
};

/// Adapts a live relay connection to the `Relay` interface.
pub const WireRelay = struct {
    client: *wir.Client,
    /// Application the bridge attached to. The relay reports disconnects for other applications on the same connection.
    application: []const u8,

    fn connectFrontend(ctx: *anyopaque, target: *const wir.Target) void {
        const self: *WireRelay = @ptrCast(@alignCast(ctx));
        self.client.connectFrontend(target) catch {};
    }

    fn sendDidClose(ctx: *anyopaque, target: *const wir.Target) void {
        const self: *WireRelay = @ptrCast(@alignCast(ctx));
        self.client.sendDidClose(target) catch {};
    }

    fn sendData(ctx: *anyopaque, target: *const wir.Target, json: []const u8) void {
        const self: *WireRelay = @ptrCast(@alignCast(ctx));
        self.client.sendData(target, self.client.sender_id, json) catch {};
    }

    fn isClosed(ctx: *anyopaque) bool {
        const self: *WireRelay = @ptrCast(@alignCast(ctx));
        return self.client.isClosed();
    }

    fn nextData(ctx: *anyopaque, timeout_ms: u64, allocator: Allocator) anyerror!?[]u8 {
        const self: *WireRelay = @ptrCast(@alignCast(ctx));
        var message = (try self.client.next(timeout_ms)) orelse return null;
        defer message.deinit(self.client.allocator);
        if (isTargetDisconnect(message.name, message.info, self.application)) return error.TargetDisconnected;
        if (std.mem.eql(u8, message.name, "_rpc_applicationDisconnected:")) return null;
        if (!std.mem.eql(u8, message.name, "_rpc_applicationSentData:")) return null;
        const data = switch (message.info.get("WIRMessageDataKey") orelse return null) {
            .data => |bytes| bytes,
            else => return null,
        };
        return try allocator.dupe(u8, data);
    }

    pub fn relay(self: *WireRelay) Relay {
        return .{ .ctx = self, .vtable = &.{
            .connectFrontend = connectFrontend,
            .sendDidClose = sendDidClose,
            .sendData = sendData,
            .isClosed = isClosed,
            .nextData = nextData,
        } };
    }
};

/// True when a relay notification reports that the application this bridge attached to is gone. The relay also reports disconnects for applications it merely listed, and those must not end the session.
pub fn isTargetDisconnect(name: []const u8, info: plist.Value, application: []const u8) bool {
    if (!std.mem.eql(u8, name, "_rpc_applicationDisconnected:")) return false;
    const disconnected = switch (info.get("WIRApplicationIdentifierKey") orelse return false) {
        .string => |text| text,
        else => return false,
    };
    return std.mem.eql(u8, disconnected, application);
}

/// The loopback transport refuses a message that would overflow its queue and, for a CDP session, closes it. A reply has to stay below that limit or the client would lose the session instead of seeing an error.
const max_frontend_bytes: usize = 3 * 1024 * 1024;

/// Adapts the loopback CDP transport to the `Frontend` interface.
pub const TransportFrontend = struct {
    transport: *transport.Transport,

    fn sendText(ctx: *anyopaque, session: transport.SessionId, text: []const u8) bool {
        const self: *TransportFrontend = @ptrCast(@alignCast(ctx));
        return self.transport.sendText(session, text);
    }

    fn closeSession(ctx: *anyopaque, session: transport.SessionId) void {
        const self: *TransportFrontend = @ptrCast(@alignCast(ctx));
        self.transport.closeSession(session);
    }

    fn boundPort(ctx: *anyopaque) u16 {
        const self: *TransportFrontend = @ptrCast(@alignCast(ctx));
        return self.transport.boundPort();
    }

    pub fn frontend(self: *TransportFrontend) Frontend {
        return .{ .ctx = self, .vtable = &.{
            .sendText = sendText,
            .closeSession = closeSession,
            .boundPort = boundPort,
        } };
    }
};

pub const Bridge = struct {
    allocator: Allocator,
    relay: Relay,
    target: wir.Target,
    frontend: Frontend,
    mutex: zev.Mutex = .{},
    /// Serializes the relay frontend registration with session add and remove. Taking it under `mutex` would order two relay calls by hash-map iteration.
    frontend_mutex: zev.Mutex = .{},
    sessions: std.ArrayListUnmanaged(Session) = .empty,
    pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,
    merges: std.AutoHashMapUnmanaged(u64, Merge) = .empty,
    scope_merges: std.StringHashMapUnmanaged([]u8) = .empty,
    scripts: std.StringHashMapUnmanaged(Script) = .empty,
    last_caller: ?CallerSite = null,
    armed_caller: ?CallerSite = null,
    /// Set by `start`, which builds the relay adapter and the CDP transport and therefore owns them.
    relay_owner: ?*WireRelay = null,
    frontend_owner: ?*TransportFrontend = null,
    next_id: u64 = 1,
    next_merge: u64 = 1,

    const Session = struct {
        id: transport.SessionId,
    };

    const Script = struct {
        url: []u8,
        end_line: i64,
        end_column: i64,
    };

    /// A pause position that a `Debugger.stepOut` returns to, taken from the frame below the frame being stepped out of.
    const CallerSite = struct {
        script_id: []u8,
        function_name: []u8,
        line: i64,
        column: i64,
    };

    const Pending = struct {
        session: transport.SessionId = 0,
        client_id: i64 = 0,
        kind: MethodKind = .other,
        merge_id: u64 = 0,
        /// Commands the bridge issues on a client's behalf. Their replies belong to no client.
        internal: bool = false,
    };

    const Merge = struct {
        session: transport.SessionId,
        client_id: i64,
        received: u8 = 0,
        parts: [2]?[]u8 = .{ null, null },
    };

    pub const MethodKind = enum {
        debugger_enable,
        evaluate,
        evaluate_on_call_frame,
        call_function_on,
        get_properties,
        other,
    };

    pub fn start(allocator: Allocator, io: std.Io, client: *wir.Client, target: wir.Target, port: u16) !*Bridge {
        _ = io;
        // Each owner starts out as a local claim and moves into the bridge as soon as the bridge exists, so a failed start releases everything through exactly one path.
        var wire: ?*WireRelay = try allocator.create(WireRelay);
        errdefer if (wire) |owner| allocator.destroy(owner);
        wire.?.client = client;
        wire.?.application = target.application;
        var frontend_owner: ?*TransportFrontend = try allocator.create(TransportFrontend);
        errdefer if (frontend_owner) |owner| allocator.destroy(owner);
        frontend_owner.?.transport = try transport.Transport.init(allocator, port);
        errdefer if (frontend_owner) |owner| owner.transport.deinit();
        const self = try init(allocator, wire.?.relay(), frontend_owner.?.frontend(), target);
        errdefer self.deinit();
        self.relay_owner = wire;
        self.frontend_owner = frontend_owner;
        wire = null;
        frontend_owner = null;
        self.frontend_owner.?.transport.setProtocolJson("{}");
        self.frontend_owner.?.transport.setDiscoveryTarget(.{
            .title = target.title,
            .kind = "node",
            .url = "",
            .id = "jsbay-jsc-target",
        });
        try self.frontend_owner.?.transport.start(self, handleEvent);
        return self;
    }

    /// Builds a bridge over the given relay and frontend. Production reaches this through `start`; tests pair it with a scripted relay.
    pub fn init(allocator: Allocator, relay: Relay, frontend: Frontend, target: wir.Target) !*Bridge {
        const self = try allocator.create(Bridge);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .relay = relay,
            .target = target,
            .frontend = frontend,
        };
        return self;
    }

    pub fn boundPort(self: *Bridge) u16 {
        return self.frontend.boundPort();
    }

    /// Releases the state the bridge owns, including the relay adapter and the CDP transport that `start` built. The target belongs to the caller.
    pub fn deinit(self: *Bridge) void {
        // The transport closes its sessions on the way down, so it has to go first: those calls still need the bridge state below.
        if (self.frontend_owner) |owner| {
            owner.transport.deinit();
            self.frontend_owner = null;
        }
        self.mutex.lock();
        self.clearScopeMergesLocked();
        self.scope_merges.deinit(self.allocator);
        var merge_iterator = self.merges.iterator();
        while (merge_iterator.next()) |entry| {
            for (entry.value_ptr.parts) |slot| {
                if (slot) |owned| self.allocator.free(owned);
            }
        }
        self.merges.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        var script_iterator = self.scripts.iterator();
        while (script_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.url);
        }
        self.scripts.deinit(self.allocator);
        replaceSite(self.allocator, &self.last_caller, null);
        replaceSite(self.allocator, &self.armed_caller, null);
        self.mutex.unlock();
        if (self.relay_owner) |owner| {
            self.relay_owner = null;
            self.allocator.destroy(owner);
        }
        if (self.frontend_owner) |owner| {
            self.frontend_owner = null;
            self.allocator.destroy(owner);
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Copies relay notifications into every session until the relay closes.
    pub fn pump(self: *Bridge) !void {
        while (true) {
            if (self.relay.isClosed()) return;
            const data = (self.relay.nextData(500, self.allocator) catch |err| switch (err) {
                // The inspected process is gone, so its relay sender is gone as well and attached clients can only be released.
                error.TargetDisconnected => return self.closeAllSessions(),
                else => return err,
            }) orelse continue;
            defer self.allocator.free(data);
            self.deliver(data);
        }
    }

    /// Detaches every client without telling the relay, which no longer has the target either.
    fn closeAllSessions(self: *Bridge) void {
        self.frontend_mutex.lock();
        defer self.frontend_mutex.unlock();
        self.mutex.lock();
        // One client at a time is the contract, so a fixed buffer covers every session that can be open.
        var ids: [4]transport.SessionId = undefined;
        var count: usize = 0;
        for (self.sessions.items) |session| {
            if (count == ids.len) break;
            ids[count] = session.id;
            count += 1;
        }
        for (ids[0..count]) |id| self.dropSessionState(id);
        self.sessions.clearRetainingCapacity();
        self.clearScopeMergesLocked();
        replaceSite(self.allocator, &self.last_caller, null);
        replaceSite(self.allocator, &self.armed_caller, null);
        self.mutex.unlock();
        for (ids[0..count]) |id| self.frontend.closeSession(id);
    }

    fn handleEvent(ctx: ?*anyopaque, event: transport.Event) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx.?));
        switch (event.kind) {
            .session_opened => self.openSession(event.session_id),
            .session_closed => self.closeSession(event.session_id),
            .message => self.onMessage(event.session_id, event.payload),
        }
    }

    pub fn openSession(self: *Bridge, id: transport.SessionId) void {
        self.frontend_mutex.lock();
        defer self.frontend_mutex.unlock();
        self.mutex.lock();
        // JSC keeps one JavaScript context and the bridge owns one relay frontend sender, so a second client would silently share breakpoint, domain, and pause state with the first. Reject it instead of running two sessions over one sender.
        if (self.sessions.items.len > 0) {
            self.mutex.unlock();
            logDrop("CDP session rejected because another session is open");
            return self.frontend.closeSession(id);
        }
        self.sessions.append(self.allocator, .{ .id = id }) catch {
            self.mutex.unlock();
            return self.frontend.closeSession(id);
        };
        self.mutex.unlock();
        // The relay forgets the frontend sender when the last client detached, so a later client needs it registered again before commands reach the target.
        self.relay.connectFrontend(&self.target);
    }

    pub fn closeSession(self: *Bridge, id: transport.SessionId) void {
        self.frontend_mutex.lock();
        defer self.frontend_mutex.unlock();
        self.mutex.lock();
        var removed = false;
        for (self.sessions.items, 0..) |session, index| {
            if (session.id == id) {
                _ = self.sessions.orderedRemove(index);
                removed = true;
                break;
            }
        }
        const empty = self.sessions.items.len == 0;
        self.dropSessionState(id);
        if (empty) {
            // The relay object ids die with the frontend sender, so a later client must not reuse them.
            self.clearScopeMergesLocked();
            replaceSite(self.allocator, &self.last_caller, null);
            replaceSite(self.allocator, &self.armed_caller, null);
        }
        self.mutex.unlock();
        if (removed and empty) self.relay.sendDidClose(&self.target);
    }

    /// Drops the requests and merges that a closed session will never collect. Caller holds `mutex`.
    fn dropSessionState(self: *Bridge, id: transport.SessionId) void {
        var pending_ids: std.ArrayListUnmanaged(u64) = .empty;
        defer pending_ids.deinit(self.allocator);
        var pending_iterator = self.pending.iterator();
        while (pending_iterator.next()) |entry| {
            if (entry.value_ptr.internal) continue;
            if (entry.value_ptr.session == id) pending_ids.append(self.allocator, entry.key_ptr.*) catch {};
        }
        for (pending_ids.items) |key| _ = self.pending.remove(key);

        var merge_ids: std.ArrayListUnmanaged(u64) = .empty;
        defer merge_ids.deinit(self.allocator);
        var merge_iterator = self.merges.iterator();
        while (merge_iterator.next()) |entry| {
            if (entry.value_ptr.session == id) merge_ids.append(self.allocator, entry.key_ptr.*) catch {};
        }
        for (merge_ids.items) |key| {
            if (self.merges.fetchRemove(key)) |removed| {
                for (removed.value.parts) |slot| if (slot) |owned| self.allocator.free(owned);
            }
        }
    }

    pub fn onMessage(self: *Bridge, session_id: transport.SessionId, payload: []const u8) void {
        self.mutex.lock();
        var attached = false;
        for (self.sessions.items) |session| {
            if (session.id == session_id) {
                attached = true;
                break;
            }
        }
        self.mutex.unlock();
        // A rejected or already closed session can still have messages in flight; those must not reach the target or the shared caller state.
        if (!attached) {
            logDrop("message from a session that is not attached");
            return;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch {
            return self.replyError(session_id, null, -32700, "Parse error");
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |map| map,
            else => return self.replyError(session_id, null, -32600, "Invalid request"),
        };
        const id = object.get("id") orelse return;
        const method = object.get("method") orelse {
            return self.replyError(session_id, id, -32600, "Invalid request");
        };
        const name = switch (method) {
            .string => |text| text,
            else => return self.replyError(session_id, id, -32600, "Invalid request"),
        };
        const params = object.get("params") orelse std.json.Value{ .null = {} };

        if (std.mem.eql(u8, name, "Runtime.getProperties")) {
            if (params == .object) {
                if (params.object.get("objectId")) |object_id| {
                    if (object_id == .string) {
                        if (self.scopePartner(object_id.string)) |partner| {
                            defer self.allocator.free(partner);
                            return self.startMergedProperties(session_id, id, params, object_id.string, partner);
                        }
                    }
                }
            }
        }
        if (!isRelayMethod(name)) return self.localReply(session_id, id, name);
        if (std.mem.eql(u8, name, "Debugger.getScriptSource")) {
            const known = if (params == .object) switch (params.object.get("scriptId") orelse std.json.Value{ .null = {} }) {
                .string => |script_id| hasScript(self, script_id),
                else => false,
            } else false;
            if (!known) return self.replyError(session_id, id, -32602, "Unknown scriptId");
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const translated = translateParams(self, arena.allocator(), name, params) catch {
            return self.replyError(session_id, id, -32603, "Translation failed");
        };
        var envelope = std.json.ObjectMap{};
        const client_id: i64 = switch (id) {
            .integer => |value| value,
            else => return self.replyError(session_id, id, -32600, "Invalid request id"),
        };
        const relay_id = self.register(session_id, client_id, kindOf(name), 0);
        envelope.put(arena.allocator(), "id", .{ .integer = @intCast(relay_id) }) catch return;
        envelope.put(arena.allocator(), "method", .{ .string = name }) catch return;
        if (translated) |value| envelope.put(arena.allocator(), "params", value) catch return;

        var writer: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = envelope }, .{}, &writer.writer) catch return;
        if (std.mem.eql(u8, name, "Debugger.stepOut")) {
            armStepOut(self);
        } else if (std.mem.eql(u8, name, "Debugger.resume") or std.mem.eql(u8, name, "Debugger.stepOver") or std.mem.eql(u8, name, "Debugger.stepInto") or std.mem.eql(u8, name, "Debugger.continueToLocation") or std.mem.eql(u8, name, "Debugger.stepOut")) {
            clearCaller(self);
        }
        self.relay.sendData(&self.target, writer.written());
        if (std.mem.eql(u8, name, "Runtime.enable")) self.sendExecutionContext(session_id);
        // A Web Inspector frontend activates breakpoints after enabling the debugger. JSC does not pause at a resolved breakpoint until that switch is on.
        if (std.mem.eql(u8, name, "Debugger.enable")) {
            self.inject("Debugger.setBreakpointsActive", "{\"active\":true}", arena.allocator());
            // JSC only pauses at `debugger` statements when the frontend arms this WebKit-specific switch. CDP has no equivalent command.
            self.inject("Debugger.setPauseOnDebuggerStatements", "{\"enabled\":true}", arena.allocator());
        }
    }

    /// JSC keeps its single JavaScript context in the inspected process and never announces it, while CDP clients wait for `Runtime.executionContextCreated` before they can evaluate anything.
    fn sendExecutionContext(self: *Bridge, session_id: transport.SessionId) void {
        const event = "{\"method\":\"Runtime.executionContextCreated\",\"params\":{\"context\":{\"id\":1,\"origin\":\"\",\"name\":\"jsbay\",\"uniqueId\":\"jsbay-context-1\",\"auxData\":{\"isDefault\":true,\"type\":\"default\"}}}}";
        _ = self.frontend.sendText(session_id, event);
    }

    fn localReply(self: *Bridge, session_id: transport.SessionId, id: std.json.Value, name: []const u8) void {
        if (std.mem.eql(u8, name, "Schema.getDomains")) return self.replyResult(session_id, id, "{\"domains\":[]}");
        if (std.mem.endsWith(u8, name, ".enable") or std.mem.endsWith(u8, name, ".disable")) return self.replyResult(session_id, id, "{}");
        if (std.mem.eql(u8, name, "Target.setAutoAttach") or std.mem.eql(u8, name, "Target.setDiscoverTargets")) return self.replyResult(session_id, id, "{}");
        if (std.mem.eql(u8, name, "Runtime.getHeapUsage")) return self.replyResult(session_id, id, "{\"usedSize\":0,\"totalSize\":0}");
        self.replyError(session_id, id, -32601, "Method not found");
    }

    fn replyResult(self: *Bridge, session_id: transport.SessionId, id: std.json.Value, result_json: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var object = std.json.ObjectMap{};
        object.put(arena.allocator(), "id", id) catch return;
        const result = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), result_json, .{}) catch return;
        object.put(arena.allocator(), "result", result) catch return;
        var writer: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = object }, .{}, &writer.writer) catch return;
        _ = self.frontend.sendText(session_id, writer.written());
    }

    fn replyError(self: *Bridge, session_id: transport.SessionId, id: ?std.json.Value, code: i64, message: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var object = std.json.ObjectMap{};
        if (id) |value| object.put(arena.allocator(), "id", value) catch return;
        var error_object = std.json.ObjectMap{};
        error_object.put(arena.allocator(), "code", .{ .integer = code }) catch return;
        error_object.put(arena.allocator(), "message", .{ .string = message }) catch return;
        object.put(arena.allocator(), "error", .{ .object = error_object }) catch return;
        var writer: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = object }, .{}, &writer.writer) catch return;
        _ = self.frontend.sendText(session_id, writer.written());
    }

    fn register(self: *Bridge, session_id: transport.SessionId, client_id: i64, kind: MethodKind, merge_id: u64) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const relay_id = self.next_id;
        self.next_id += 1;
        self.pending.put(self.allocator, relay_id, .{ .session = session_id, .client_id = client_id, .kind = kind, .merge_id = merge_id }) catch {};
        return relay_id;
    }

    /// Reserves a relay id for a command the bridge issues itself. The reply is dropped instead of routed to a client.
    fn registerInternal(self: *Bridge) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const relay_id = self.next_id;
        self.next_id += 1;
        self.pending.put(self.allocator, relay_id, .{ .internal = true }) catch {};
        return relay_id;
    }

    fn inject(self: *Bridge, method: []const u8, params_json: []const u8, allocator: Allocator) void {
        const relay_id = self.registerInternal();
        const json = std.fmt.allocPrint(allocator, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ relay_id, method, params_json }) catch return;
        self.relay.sendData(&self.target, json);
    }

    /// Owned copy of the paired object id. The map entry can be replaced by a later pause while the request is in flight.
    fn scopePartner(self: *Bridge, object_id: []const u8) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const partner = self.scope_merges.get(object_id) orelse return null;
        return self.allocator.dupe(u8, partner) catch null;
    }

    fn clearScopeMergesLocked(self: *Bridge) void {
        var iterator = self.scope_merges.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.scope_merges.clearRetainingCapacity();
    }

    fn recordScopeMerge(self: *Bridge, local_id: []const u8, block_id: []const u8) void {
        const key = self.allocator.dupe(u8, local_id) catch return;
        const value = self.allocator.dupe(u8, block_id) catch {
            self.allocator.free(key);
            return;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.scope_merges.fetchPut(self.allocator, key, value) catch null) |previous| {
            self.allocator.free(previous.key);
            self.allocator.free(previous.value);
        }
    }

    fn startMergedProperties(self: *Bridge, session_id: transport.SessionId, id: std.json.Value, params: std.json.Value, primary: []const u8, secondary: []const u8) void {
        const client_id: i64 = switch (id) {
            .integer => |value| value,
            else => return self.replyError(session_id, id, -32602, "Invalid request id"),
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        self.mutex.lock();
        const merge_id = self.next_merge;
        self.next_merge += 1;
        self.merges.put(self.allocator, merge_id, .{ .session = session_id, .client_id = client_id }) catch {
            self.mutex.unlock();
            return self.replyError(session_id, id, -32603, "Merge state unavailable");
        };
        self.mutex.unlock();
        const ids = [_][]const u8{ primary, secondary };
        for (ids) |object_id| {
            var filtered = std.json.ObjectMap{};
            var iterator = params.object.iterator();
            while (iterator.next()) |entry| filtered.put(arena.allocator(), entry.key_ptr.*, entry.value_ptr.*) catch {};
            filtered.put(arena.allocator(), "objectId", .{ .string = object_id }) catch {};
            var envelope = std.json.ObjectMap{};
            const relay_id = self.register(session_id, client_id, .get_properties, merge_id);
            envelope.put(arena.allocator(), "id", .{ .integer = @intCast(relay_id) }) catch return;
            envelope.put(arena.allocator(), "method", .{ .string = "Runtime.getProperties" }) catch return;
            envelope.put(arena.allocator(), "params", .{ .object = filtered }) catch return;
            var writer: std.Io.Writer.Allocating = .init(arena.allocator());
            std.json.Stringify.value(std.json.Value{ .object = envelope }, .{}, &writer.writer) catch return;
            self.relay.sendData(&self.target, writer.written());
        }
    }

    fn mergePart(self: *Bridge, merge_id: u64, object: std.json.ObjectMap) void {
        const properties = extractProperties(self.allocator, object);
        self.mutex.lock();
        const entry = self.merges.getPtr(merge_id) orelse {
            self.mutex.unlock();
            if (properties) |owned| self.allocator.free(owned);
            logDrop("merged reply for an unknown merge");
            return;
        };
        const slot = entry.received;
        if (slot < entry.parts.len) entry.parts[slot] = properties else if (properties) |owned| self.allocator.free(owned);
        entry.received += 1;
        if (entry.received < entry.parts.len) {
            self.mutex.unlock();
            return;
        }
        const session = entry.session;
        const client_id = entry.client_id;
        const first = entry.parts[0];
        const second = entry.parts[1];
        _ = self.merges.remove(merge_id);
        self.mutex.unlock();
        defer if (first) |owned| self.allocator.free(owned);
        defer if (second) |owned| self.allocator.free(owned);
        if (first == null and second == null) return self.replyError(session, .{ .integer = client_id }, -32603, "Scope properties unavailable");

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var combined = std.json.Array.init(arena.allocator());
        for ([_]?[]const u8{ first, second }) |part| {
            const owned = part orelse continue;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), owned, .{}) catch continue;
            if (parsed != .array) continue;
            for (parsed.array.items) |item| combined.append(item) catch {};
        }
        var result_map = std.json.ObjectMap{};
        result_map.put(arena.allocator(), "result", .{ .array = combined }) catch return;
        var response = std.json.ObjectMap{};
        response.put(arena.allocator(), "id", .{ .integer = client_id }) catch return;
        response.put(arena.allocator(), "result", .{ .object = result_map }) catch return;
        var out: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = response }, .{}, &out.writer) catch return;
        self.sendReply(session, client_id, out.written());
    }

    /// Serializes the `properties` array of a `Runtime.getProperties` reply, or null when the relay reported an error for that half.
    fn extractProperties(allocator: Allocator, object: std.json.ObjectMap) ?[]u8 {
        const result_value = object.get("result") orelse return null;
        if (result_value != .object) return null;
        const properties = result_value.object.get("properties") orelse return null;
        if (properties != .array) return null;
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        std.json.Stringify.value(properties, .{}, &writer.writer) catch return null;
        return allocator.dupe(u8, writer.written()) catch null;
    }

    /// Routes one relay notification or reply. Exposed so tests can feed scripted relay traffic.
    pub fn deliver(self: *Bridge, data: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            logDrop("relay data that is not JSON");
            return;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |map| map,
            else => {
                logDrop("relay data that is not a JSON object");
                return;
            },
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var copy = object;
        if (object.get("method") != null) {
            copy = postProcessEvent(self, arena.allocator(), object) catch {
                logDrop("relay event that could not be translated");
                return;
            };
            self.broadcast(arena.allocator(), copy);
            return;
        }
        const id = object.get("id") orelse {
            logDrop("relay message without an id or method");
            return;
        };
        const relay_id: u64 = switch (id) {
            .integer => |value| if (value >= 0) @intCast(value) else {
                logDrop("relay reply with a negative id");
                return;
            },
            else => {
                logDrop("relay reply with a non-integer id");
                return;
            },
        };
        const pending = self.take(relay_id) orelse {
            logDrop("relay reply for an unknown or already answered id");
            return;
        };
        if (pending.internal) return;
        if (pending.merge_id != 0) return self.mergePart(pending.merge_id, object);
        copy.put(arena.allocator(), "id", .{ .integer = pending.client_id }) catch return;
        if (pending.kind != .other) copy = postProcessReply(arena.allocator(), copy, pending.kind) catch {
            logDrop("relay reply that could not be translated");
            return;
        };
        var writer: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = copy }, .{}, &writer.writer) catch return;
        self.sendReply(pending.session, pending.client_id, writer.written());
    }

    /// Answers a client, turning a message the transport cannot carry into an error reply so the request is not left hanging.
    fn sendReply(self: *Bridge, session: transport.SessionId, client_id: i64, text: []const u8) void {
        if (text.len > max_frontend_bytes) {
            logDrop("reply larger than the transport accepts");
            return self.replyError(session, .{ .integer = client_id }, -32000, "Reply exceeds the CDP transport message limit");
        }
        if (!self.frontend.sendText(session, text)) {
            logDrop("reply the transport refused");
            return self.replyError(session, .{ .integer = client_id }, -32000, "Reply could not be queued for delivery");
        }
    }

    fn take(self: *Bridge, relay_id: u64) ?Pending {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.pending.fetchRemove(relay_id) orelse return null;
        return entry.value;
    }

    fn broadcast(self: *Bridge, allocator: Allocator, object: std.json.ObjectMap) void {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        std.json.Stringify.value(std.json.Value{ .object = object }, .{}, &writer.writer) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |session| {
            _ = self.frontend.sendText(session.id, writer.written());
        }
    }
};

fn kindOf(name: []const u8) Bridge.MethodKind {
    if (std.mem.eql(u8, name, "Debugger.enable")) return .debugger_enable;
    if (std.mem.eql(u8, name, "Runtime.evaluate")) return .evaluate;
    if (std.mem.eql(u8, name, "Debugger.evaluateOnCallFrame")) return .evaluate_on_call_frame;
    if (std.mem.eql(u8, name, "Runtime.callFunctionOn")) return .call_function_on;
    if (std.mem.eql(u8, name, "Runtime.getProperties")) return .get_properties;
    return .other;
}

fn isRelayMethod(name: []const u8) bool {
    const methods = [_][]const u8{
        "Runtime.enable",
        "Runtime.disable",
        "Runtime.evaluate",
        "Runtime.callFunctionOn",
        "Runtime.getProperties",
        "Runtime.releaseObject",
        "Runtime.releaseObjectGroup",
        "Runtime.discardConsoleEntries",
        "Runtime.getIsolateId",
        "Debugger.enable",
        "Debugger.disable",
        "Debugger.setBreakpointsActive",
        "Debugger.setBreakpointByUrl",
        "Debugger.setBreakpoint",
        "Debugger.removeBreakpoint",
        "Debugger.continueToLocation",
        "Debugger.pause",
        "Debugger.resume",
        "Debugger.stepOver",
        "Debugger.stepInto",
        "Debugger.stepOut",
        "Debugger.setPauseOnExceptions",
        "Debugger.evaluateOnCallFrame",
        "Debugger.getScriptSource",
        "Debugger.getPossibleBreakpoints",
        "Debugger.searchInContent",
        "Debugger.setBlackboxPatterns",
        "Debugger.setAsyncStackTraceDepth",
        "Debugger.setInstrumentationBreakpoint",
        "Debugger.setBreakpointOnFunctionCall",
    };
    for (methods) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const evaluate_keys = [_][]const u8{
    "expression",        "objectGroup",   "includeCommandLineAPI", "doNotPauseOnExceptionsAndMuteConsole",
    "contextId",         "returnByValue", "generatePreview",       "userGesture",
    "awaitPromise",      "REPLMode",      "emulateUserGesture",    "uniqueContextId",
    "throwOnSideEffect", "timeout",
};

const call_function_keys = [_][]const u8{
    "functionDeclaration", "objectId",        "arguments",          "doNotPauseOnExceptionsAndMuteConsole",
    "returnByValue",       "generatePreview", "emulateUserGesture", "awaitPromise",
    "objectGroup",
};

const get_properties_keys = [_][]const u8{
    "objectId", "ownProperties", "generatePreview", "nonIndexedPropertiesOnly", "accessorPropertiesOnly",
};

const evaluate_on_call_frame_keys = [_][]const u8{
    "callFrameId",   "expression",      "objectGroup",        "includeCommandLineAPI",
    "returnByValue", "generatePreview", "emulateUserGesture",
};

/// JSC resolves a breakpoint per statement, so a column offset is dropped to keep the breakpoint on the statement under the client's cursor. Two cases keep it: a single-line script, where the column is the only way to name a statement, and `continueToLocation`, where zeroing the column moves the target behind the position execution resumes from.
fn dropStatementOffset(self: *Bridge, method: []const u8, params: *std.json.ObjectMap) void {
    if (std.mem.eql(u8, method, "Debugger.continueToLocation")) return;
    if (targetsSingleLineScript(self, params.*)) return;
    if (params.getPtr("columnNumber")) |column| {
        if (column.* == .integer and column.integer > 0) column.* = .{ .integer = 0 };
    }
    const location = params.getPtr("location") orelse return;
    if (location.* != .object) return;
    if (location.object.getPtr("columnNumber")) |column| {
        if (column.* == .integer and column.integer > 0) column.* = .{ .integer = 0 };
    }
}

fn targetsSingleLineScript(self: *Bridge, params: std.json.ObjectMap) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (scriptIdOf(params)) |script_id| {
        if (self.scripts.get(script_id)) |script| return script.end_line == 0;
    }
    const url = switch (params.get("url") orelse return false) {
        .string => |text| text,
        else => return false,
    };
    // One URL can match several parsed scripts, for example after a reload. The column is kept only when every match is single-line, because a multi-line match would place the breakpoint at the statement under the offset rather than at the start of the line.
    var matched = false;
    var iterator = self.scripts.iterator();
    while (iterator.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.url, url)) continue;
        if (entry.value_ptr.end_line != 0) return false;
        matched = true;
    }
    return matched;
}

fn scriptIdOf(params: std.json.ObjectMap) ?[]const u8 {
    if (params.get("scriptId")) |value| {
        if (value == .string) return value.string;
    }
    const location = params.get("location") orelse return null;
    if (location != .object) return null;
    const nested = location.object.get("scriptId") orelse return null;
    return if (nested == .string) nested.string else null;
}

fn translateParams(self: *Bridge, allocator: Allocator, method: []const u8, params: std.json.Value) !?std.json.Value {
    if (params != .object) return null;
    const source = params.object;
    if (std.mem.eql(u8, method, "Debugger.setBreakpointByUrl") or std.mem.eql(u8, method, "Debugger.setBreakpoint") or std.mem.eql(u8, method, "Debugger.continueToLocation")) {
        var filtered = std.json.ObjectMap{};
        var iterator = source.iterator();
        while (iterator.next()) |entry| filtered.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch {};
        if (source.get("condition")) |condition| {
            var options = std.json.ObjectMap{};
            options.put(allocator, "condition", condition) catch {};
            filtered.put(allocator, "options", .{ .object = options }) catch {};
            _ = filtered.swapRemove("condition");
        }
        dropStatementOffset(self, method, &filtered);
        return .{ .object = filtered };
    }
    const allowed: ?[]const []const u8 = if (std.mem.eql(u8, method, "Runtime.evaluate"))
        &evaluate_keys
    else if (std.mem.eql(u8, method, "Runtime.callFunctionOn"))
        &call_function_keys
    else if (std.mem.eql(u8, method, "Runtime.getProperties"))
        &get_properties_keys
    else if (std.mem.eql(u8, method, "Debugger.evaluateOnCallFrame"))
        &evaluate_on_call_frame_keys
    else
        null;
    if (allowed) |keys| {
        var filtered = std.json.ObjectMap{};
        for (keys) |key| {
            if (source.get(key)) |value| filtered.put(allocator, key, value) catch {};
        }
        // The bridge advertises one synthetic context; the relay addresses the only context the target has.
        _ = filtered.swapRemove("contextId");
        _ = filtered.swapRemove("uniqueContextId");
        // CDP spells the option that keeps a throwing evaluation from pausing the target differently from the relay.
        if (std.mem.eql(u8, method, "Runtime.evaluate")) {
            const silent = switch (source.get("silent") orelse std.json.Value{ .bool = false }) {
                .bool => |flag| flag,
                else => false,
            };
            if (silent and source.get("doNotPauseOnExceptionsAndMuteConsole") == null) {
                filtered.put(allocator, "doNotPauseOnExceptionsAndMuteConsole", .{ .bool = true }) catch {};
            }
        }
        return .{ .object = filtered };
    }
    return .{ .object = source };
}

fn scriptUrl(self: *Bridge, script_id: []const u8) ?[]const u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const script = self.scripts.get(script_id) orelse return null;
    return script.url;
}

fn hasScript(self: *Bridge, script_id: []const u8) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.scripts.contains(script_id);
}

fn recordScript(self: *Bridge, params: std.json.ObjectMap) void {
    const script_id = switch (params.get("scriptId") orelse return) {
        .string => |text| text,
        else => return,
    };
    const raw_url = switch (params.get("url") orelse std.json.Value{ .string = "" }) {
        .string => |text| text,
        else => "",
    };
    const source_url = switch (params.get("sourceURL") orelse std.json.Value{ .string = "" }) {
        .string => |text| text,
        else => "",
    };
    const url = if (raw_url.len != 0) raw_url else source_url;
    const owned_url = self.allocator.dupe(u8, url) catch return;
    const owned_key = self.allocator.dupe(u8, script_id) catch {
        self.allocator.free(owned_url);
        return;
    };
    const script = Bridge.Script{
        .url = owned_url,
        .end_line = switch (params.get("endLine") orelse std.json.Value{ .integer = -1 }) {
            .integer => |value| value,
            else => -1,
        },
        .end_column = switch (params.get("endColumn") orelse std.json.Value{ .integer = -1 }) {
            .integer => |value| value,
            else => -1,
        },
    };
    self.mutex.lock();
    defer self.mutex.unlock();
    const entry = self.scripts.getOrPut(self.allocator, owned_key) catch {
        self.allocator.free(owned_key);
        self.allocator.free(owned_url);
        return;
    };
    if (entry.found_existing) {
        self.allocator.free(owned_key);
        self.allocator.free(entry.value_ptr.url);
    }
    entry.value_ptr.* = script;
}

fn replaceSite(allocator: Allocator, slot: *?Bridge.CallerSite, site: ?Bridge.CallerSite) void {
    if (slot.*) |*previous| {
        allocator.free(previous.script_id);
        allocator.free(previous.function_name);
    }
    slot.* = site;
}

fn callerSite(allocator: Allocator, frame: std.json.Value) !Bridge.CallerSite {
    if (frame != .object) return error.MissingFrame;
    const location = frame.object.get("location") orelse return error.MissingFrame;
    if (location != .object) return error.MissingFrame;
    const script = location.object.get("scriptId") orelse return error.MissingFrame;
    if (script != .string) return error.MissingFrame;
    const line = switch (location.object.get("lineNumber") orelse return error.MissingFrame) {
        .integer => |value| value,
        else => return error.MissingFrame,
    };
    if (line < 0) return error.MissingFrame;
    const column = switch (location.object.get("columnNumber") orelse std.json.Value{ .integer = 0 }) {
        .integer => |value| @max(value, 0),
        else => 0,
    };
    const function_name = switch (frame.object.get("functionName") orelse std.json.Value{ .string = "" }) {
        .string => |text| text,
        else => "",
    };
    return .{
        .script_id = try allocator.dupe(u8, script.string),
        .function_name = try allocator.dupe(u8, function_name),
        .line = line,
        .column = column,
    };
}

/// Remembers where the frame below the current top frame is paused, so a later step out can report that call site.
fn storeCaller(self: *Bridge, frames: std.json.Array) void {
    if (frames.items.len < 2) return clearCaller(self);
    const site = callerSite(self.allocator, frames.items[1]) catch return clearCaller(self);
    self.mutex.lock();
    defer self.mutex.unlock();
    replaceSite(self.allocator, &self.last_caller, site);
}

fn armStepOut(self: *Bridge) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    replaceSite(self.allocator, &self.armed_caller, null);
    const caller = self.last_caller orelse return;
    const copy = copyCallerSite(self, caller) catch return;
    self.armed_caller = copy;
}

fn copyCallerSite(self: *Bridge, site: Bridge.CallerSite) !Bridge.CallerSite {
    const script_id = try self.allocator.dupe(u8, site.script_id);
    errdefer self.allocator.free(script_id);
    return .{
        .script_id = script_id,
        .function_name = try self.allocator.dupe(u8, site.function_name),
        .line = site.line,
        .column = site.column,
    };
}

fn clearCaller(self: *Bridge) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    replaceSite(self.allocator, &self.last_caller, null);
    replaceSite(self.allocator, &self.armed_caller, null);
}

/// JSC reports the position after the last top-level statement once a step out leaves the outermost statement. Other CDP engines report the call site the frame is returning to.
fn normalizeStepOutPause(self: *Bridge, allocator: Allocator, params: *const std.json.ObjectMap) void {
    const frames = switch (params.get("callFrames") orelse return) {
        .array => |items| items,
        else => return,
    };
    if (frames.items.len == 0) return;
    const top = &frames.items[0];
    if (top.* != .object) return;
    const location = top.object.get("location") orelse return;
    if (location != .object) return;
    const script_value = location.object.get("scriptId") orelse return;
    if (script_value != .string) return;
    const line = switch (location.object.get("lineNumber") orelse return) {
        .integer => |value| value,
        else => return,
    };
    const column = switch (location.object.get("columnNumber") orelse std.json.Value{ .integer = 0 }) {
        .integer => |value| value,
        else => 0,
    };
    self.mutex.lock();
    defer self.mutex.unlock();
    const armed = self.armed_caller orelse return;
    if (!std.mem.eql(u8, armed.script_id, script_value.string)) return;
    const script = self.scripts.get(script_value.string) orelse return;
    if (script.end_line < 0) return;
    const at_end = line == script.end_line and (column == script.end_column or script.end_column < 0);
    const past_end = line > script.end_line;
    if (!at_end and !past_end) return;
    // The event outlives the caller site, so it needs its own copy of both strings before the site is released.
    const script_id = allocator.dupe(u8, armed.script_id) catch return;
    const function_name = allocator.dupe(u8, armed.function_name) catch return;
    var rewritten = std.json.ObjectMap{};
    rewritten.put(allocator, "scriptId", .{ .string = script_id }) catch return;
    rewritten.put(allocator, "lineNumber", .{ .integer = armed.line }) catch return;
    rewritten.put(allocator, "columnNumber", .{ .integer = armed.column }) catch return;
    top.object.put(allocator, "location", .{ .object = rewritten }) catch return;
    top.object.put(allocator, "functionName", .{ .string = function_name }) catch return;
    replaceSite(self.allocator, &self.armed_caller, null);
}

fn postProcessEvent(self: *Bridge, allocator: Allocator, object: std.json.ObjectMap) !std.json.ObjectMap {
    const method = switch (object.get("method") orelse return object) {
        .string => |text| text,
        else => return object,
    };
    // The relay sends this notification without params, so it is handled before the params check. The pause that owned the scope pairing is over, however execution resumed; a resume command the target rejected keeps the pairing because the target stays paused.
    if (std.mem.eql(u8, method, "Debugger.resumed")) {
        self.mutex.lock();
        self.clearScopeMergesLocked();
        self.mutex.unlock();
    }
    const params_value = object.getPtr("params") orelse return object;
    var params = switch (params_value.*) {
        .object => |*map| map,
        else => return object,
    };
    if (std.mem.eql(u8, method, "Debugger.scriptParsed")) {
        if (params.getPtr("url")) |url_value| {
            if (url_value.* == .string and url_value.string.len == 0) {
                if (params.get("sourceURL")) |source| {
                    if (source == .string and source.string.len != 0) url_value.* = .{ .string = source.string };
                }
            }
        }
        recordScript(self, params.*);
        return object;
    }
    if (!std.mem.eql(u8, method, "Debugger.paused")) return object;
    const reason = params.get("reason") orelse return object;
    if (reason == .string) {
        const mapped: ?[]const u8 = if (std.mem.eql(u8, reason.string, "Breakpoint") or std.mem.eql(u8, reason.string, "DebuggerStatement") or std.mem.eql(u8, reason.string, "PauseOnNextStatement"))
            "other"
        else if (std.mem.eql(u8, reason.string, "FunctionCall"))
            "instrumentation"
        else if (std.mem.eql(u8, reason.string, "BlackboxedScript"))
            "other"
        else
            null;
        if (mapped) |replacement| params.put(allocator, "reason", .{ .string = replacement }) catch {};
    }
    if (reason == .string and std.mem.eql(u8, reason.string, "Breakpoint")) {
        if (params.get("data")) |data| {
            if (data == .object) {
                if (data.object.get("breakpointId")) |breakpoint| {
                    var hit = std.json.Array.init(allocator);
                    hit.append(breakpoint) catch {};
                    params.put(allocator, "hitBreakpoints", .{ .array = hit }) catch {};
                }
            }
        }
    }
    // CDP has a fixed scope type enumeration; the relay uses its own lexical scope names.
    if (params.get("callFrames")) |frames| {
        if (frames == .array) {
            for (frames.array.items) |frame| {
                if (frame != .object) continue;
                const scope_chain = frame.object.get("scopeChain") orelse continue;
                if (scope_chain != .array) continue;
                var seen_closure = false;
                var block_object: ?[]const u8 = null;
                var local_object: ?[]const u8 = null;
                for (scope_chain.array.items) |scope| {
                    if (scope != .object) continue;
                    const scope_type = scope.object.get("type") orelse continue;
                    if (scope_type != .string) continue;
                    const is_closure = std.mem.eql(u8, scope_type.string, "closure");
                    const is_block = std.mem.eql(u8, scope_type.string, "nestedLexical");
                    if (is_block or is_closure) {
                        if (scope.object.get("object")) |scope_object| {
                            if (scope_object == .object) {
                                if (scope_object.object.get("objectId")) |object_id| {
                                    if (object_id == .string) {
                                        if (is_block and block_object == null) block_object = object_id.string;
                                        if (is_closure and !seen_closure and local_object == null) local_object = object_id.string;
                                    }
                                }
                            }
                        }
                    }
                    const mapped: ?[]const u8 = if (std.mem.eql(u8, scope_type.string, "nestedLexical"))
                        "block"
                    else if (std.mem.eql(u8, scope_type.string, "globalLexicalEnvironment"))
                        "script"
                    else if (is_closure)
                        if (seen_closure) null else "local"
                    else
                        null;
                    if (is_closure) seen_closure = true;
                    if (mapped) |replacement| {
                        if (scope.object.getPtr("type")) |slot| slot.* = .{ .string = replacement };
                    }
                }
                if (block_object != null and local_object != null) self.recordScopeMerge(local_object.?, block_object.?);
            }
        }
    }
    // CDP call frames carry the script URL; the relay keeps it only in `Debugger.scriptParsed`.
    if (params.getPtr("callFrames")) |frames_value| {
        if (frames_value.* == .array) {
            for (frames_value.array.items) |*frame| {
                if (frame.* != .object) continue;
                // CDP names the top-level script frame with an empty name; the relay calls that frame global code.
                if (frame.object.getPtr("functionName")) |name_value| {
                    if (name_value.* == .string and std.mem.eql(u8, name_value.string, "global code")) name_value.* = .{ .string = "" };
                }
                if (frame.object.get("url") != null) continue;
                const location = frame.object.get("location") orelse continue;
                if (location != .object) continue;
                const script_value = location.object.get("scriptId") orelse continue;
                if (script_value != .string) continue;
                const borrowed = scriptUrl(self, script_value.string) orelse continue;
                // The script map can drop this slice on a later pause, so the reply keeps its own copy.
                const url = allocator.dupe(u8, borrowed) catch continue;
                frame.object.put(allocator, "url", .{ .string = url }) catch {};
            }
            normalizeStepOutPause(self, allocator, params);
            storeCaller(self, frames_value.array);
        }
    }
    return object;
}

fn postProcessReply(allocator: Allocator, object: std.json.ObjectMap, kind: Bridge.MethodKind) !std.json.ObjectMap {
    const result_value = object.getPtr("result") orelse return object;
    var result = switch (result_value.*) {
        .object => |*map| map,
        else => return object,
    };
    switch (kind) {
        .debugger_enable => {
            if (result.get("debuggerId") == null) result.put(allocator, "debuggerId", .{ .string = "jsbay-jsc-bridge" }) catch {};
        },
        .evaluate, .evaluate_on_call_frame, .call_function_on => {
            if (kind == .evaluate) result.put(allocator, "executionContextId", .{ .integer = 1 }) catch {};
            const thrown = switch (result.get("wasThrown") orelse std.json.Value{ .bool = false }) {
                .bool => |flag| flag,
                else => false,
            };
            if (thrown) {
                var details = std.json.ObjectMap{};
                details.put(allocator, "exceptionId", .{ .integer = 1 }) catch {};
                details.put(allocator, "text", .{ .string = "Uncaught" }) catch {};
                details.put(allocator, "lineNumber", .{ .integer = 0 }) catch {};
                details.put(allocator, "columnNumber", .{ .integer = 0 }) catch {};
                if (result.get("result")) |exception| details.put(allocator, "exception", exception) catch {};
                result.put(allocator, "exceptionDetails", .{ .object = details }) catch {};
            }
            _ = result.swapRemove("wasThrown");
        },
        .get_properties => {
            if (result.get("properties")) |properties| {
                result.put(allocator, "result", properties) catch {};
                _ = result.swapRemove("properties");
            }
        },
        .other => {},
    }
    return object;
}
