//! CDP to WebKit Inspector Relay translation.
//!
//! One relay connection carries a single registered frontend sender, so the bridge owns the sender
//! identity for the target. Every CDP session reuses it, and the bridge rewrites command ids to
//! unique relay ids to route the matching reply back to the session that issued it. Relay
//! notifications are copied to every attached session.

const std = @import("std");
const wir = @import("wir.zig");
const transport = @import("inspector_transport");
const zev = @import("zev");

const Allocator = std.mem.Allocator;

pub const Bridge = struct {
    allocator: Allocator,
    io: std.Io,
    client: *wir.Client,
    target: wir.Target,
    transport: *transport.Transport,
    mutex: zev.Mutex = .{},
    sessions: std.ArrayListUnmanaged(Session) = .empty,
    pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,
    merges: std.AutoHashMapUnmanaged(u64, Merge) = .empty,
    scope_merges: std.StringHashMapUnmanaged([]u8) = .empty,
    scripts: std.StringHashMapUnmanaged([]u8) = .empty,
    next_id: u64 = 1,
    next_merge: u64 = 1,

    const Session = struct {
        id: transport.SessionId,
    };

    const Pending = struct {
        session: transport.SessionId,
        client_id: i64,
        kind: MethodKind,
        merge_id: u64 = 0,
    };

    const Merge = struct {
        session: transport.SessionId,
        client_id: i64,
        received: u8 = 0,
        first: ?[]u8 = null,
    };

    pub const MethodKind = enum {
        debugger_enable,
        evaluate,
        evaluate_on_call_frame,
        get_properties,
        other,
    };

    pub fn start(allocator: Allocator, io: std.Io, client: *wir.Client, target: wir.Target, port: u16) !*Bridge {
        const self = try allocator.create(Bridge);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .target = target,
            .transport = try transport.Transport.init(allocator, port),
        };
        errdefer self.transport.deinit();
        self.transport.setProtocolJson("{}");
        self.transport.setDiscoveryTarget(.{
            .title = target.title,
            .kind = "node",
            .url = "",
            .id = target.title,
        });
        try self.transport.start(self, handleEvent);
        return self;
    }

    pub fn boundPort(self: *Bridge) u16 {
        return self.transport.boundPort();
    }

    /// Copies relay notifications into every session until the relay closes.
    pub fn pump(self: *Bridge) !void {
        while (true) {
            if (self.client.isClosed()) return;
            var message = (try self.client.next(500)) orelse continue;
            defer message.deinit(self.allocator);
            if (!std.mem.eql(u8, message.name, "_rpc_applicationSentData:")) continue;
            const data = switch (message.info.get("WIRMessageDataKey") orelse continue) {
                .data => |bytes| bytes,
                else => continue,
            };
            self.deliver(data);
        }
    }

    fn handleEvent(ctx: ?*anyopaque, event: transport.Event) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx.?));
        switch (event.kind) {
            .session_opened => self.openSession(event.session_id),
            .session_closed => self.closeSession(event.session_id),
            .message => self.onMessage(event.session_id, event.payload),
        }
    }

    fn openSession(self: *Bridge, id: transport.SessionId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sessions.append(self.allocator, .{ .id = id }) catch {
            self.transport.closeSession(id);
        };
    }

    fn closeSession(self: *Bridge, id: transport.SessionId) void {
        self.mutex.lock();
        for (self.sessions.items, 0..) |session, index| {
            if (session.id == id) {
                _ = self.sessions.orderedRemove(index);
                break;
            }
        }
        const empty = self.sessions.items.len == 0;
        self.mutex.unlock();
        if (empty) self.client.sendDidClose(&self.target) catch {};
    }

    fn onMessage(self: *Bridge, session_id: transport.SessionId, payload: []const u8) void {
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
                            return self.startMergedProperties(session_id, id, params, object_id.string, partner);
                        }
                    }
                }
            }
        }
        if (!isRelayMethod(name)) return self.localReply(session_id, id, name);
        if (std.mem.eql(u8, name, "Debugger.getScriptSource")) {
            const known = if (params == .object) switch (params.object.get("scriptId") orelse std.json.Value{ .null = {} }) {
                .string => |script_id| scriptUrl(self, script_id) != null,
                else => false,
            } else false;
            if (!known) return self.replyError(session_id, id, -32602, "Unknown scriptId");
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const translated = translateParams(arena.allocator(), name, params) catch {
            return self.replyError(session_id, id, -32603, "Translation failed");
        };
        var envelope = std.json.ObjectMap{};
        const client_id: ?i64 = switch (id) {
            .integer => |value| value,
            else => null,
        };
        const relay_id = if (client_id) |value| self.register(session_id, value, kindOf(name), 0) else 0;
        envelope.put(arena.allocator(), "id", if (client_id != null) .{ .integer = @intCast(relay_id) } else id) catch return;
        envelope.put(arena.allocator(), "method", .{ .string = name }) catch return;
        if (translated) |value| envelope.put(arena.allocator(), "params", value) catch return;

        var writer: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = envelope }, .{}, &writer.writer) catch return;
        self.client.sendData(&self.target, self.client.sender_id, writer.written()) catch {};
        // A Web Inspector frontend activates breakpoints after enabling the debugger. JSC does not pause at a resolved breakpoint until that switch is on.
        if (std.mem.eql(u8, name, "Debugger.enable")) {
            self.client.sendData(&self.target, self.client.sender_id, "{\"id\":1000000,\"method\":\"Debugger.setBreakpointsActive\",\"params\":{\"active\":true}}") catch {};
        }
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
        _ = self.transport.sendText(session_id, writer.written());
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
        _ = self.transport.sendText(session_id, writer.written());
    }

    fn register(self: *Bridge, session_id: transport.SessionId, client_id: i64, kind: MethodKind, merge_id: u64) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const relay_id = self.next_id;
        self.next_id += 1;
        self.pending.put(self.allocator, relay_id, .{ .session = session_id, .client_id = client_id, .kind = kind, .merge_id = merge_id }) catch {};
        return relay_id;
    }

    fn scopePartner(self: *Bridge, object_id: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.scope_merges.get(object_id);
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
            self.client.sendData(&self.target, self.client.sender_id, writer.written()) catch return;
        }
    }

    fn mergePart(self: *Bridge, merge_id: u64, object: std.json.ObjectMap) void {
        const result_value = object.get("result") orelse return;
        if (result_value != .object) return;
        const properties = result_value.object.get("properties") orelse return;
        if (properties != .array) return;
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        std.json.Stringify.value(properties, .{}, &writer.writer) catch return;
        const owned = self.allocator.dupe(u8, writer.written()) catch return;

        self.mutex.lock();
        const entry = self.merges.getPtr(merge_id);
        if (entry == null) {
            self.mutex.unlock();
            self.allocator.free(owned);
            return;
        }
        if (entry.?.received == 0) {
            entry.?.first = owned;
            entry.?.received = 1;
            self.mutex.unlock();
            return;
        }
        const first = entry.?.first.?;
        const session = entry.?.session;
        const client_id = entry.?.client_id;
        _ = self.merges.remove(merge_id);
        self.mutex.unlock();
        defer self.allocator.free(first);
        defer self.allocator.free(owned);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const left = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), first, .{}) catch return;
        const right = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), owned, .{}) catch return;
        if (left != .array or right != .array) return;
        var combined = std.json.Array.init(arena.allocator());
        for (left.array.items) |item| combined.append(item) catch {};
        for (right.array.items) |item| combined.append(item) catch {};
        var result_map = std.json.ObjectMap{};
        result_map.put(arena.allocator(), "result", .{ .array = combined }) catch return;
        var response = std.json.ObjectMap{};
        response.put(arena.allocator(), "id", .{ .integer = client_id }) catch return;
        response.put(arena.allocator(), "result", .{ .object = result_map }) catch return;
        var out: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = response }, .{}, &out.writer) catch return;
        _ = self.transport.sendText(session, out.written());
    }

    fn deliver(self: *Bridge, data: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |map| map,
            else => return,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var copy = object;
        if (object.get("method") != null) {
            copy = postProcessEvent(self, arena.allocator(), object) catch return;
            self.broadcast(arena.allocator(), copy);
            return;
        }
        const id = object.get("id") orelse return;
        const relay_id: u64 = switch (id) {
            .integer => |value| if (value >= 0) @intCast(value) else return,
            else => return,
        };
        const pending = self.take(relay_id) orelse return;
        if (pending.merge_id != 0) return self.mergePart(pending.merge_id, object);
        copy.put(arena.allocator(), "id", .{ .integer = pending.client_id }) catch return;
        if (pending.kind != .other) copy = postProcessReply(arena.allocator(), copy, pending.kind) catch return;
        var writer: std.Io.Writer.Allocating = .init(arena.allocator());
        std.json.Stringify.value(std.json.Value{ .object = copy }, .{}, &writer.writer) catch return;
        _ = self.transport.sendText(pending.session, writer.written());
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
            _ = self.transport.sendText(session.id, writer.written());
        }
    }
};

fn kindOf(name: []const u8) Bridge.MethodKind {
    if (std.mem.eql(u8, name, "Debugger.enable")) return .debugger_enable;
    if (std.mem.eql(u8, name, "Runtime.evaluate")) return .evaluate;
    if (std.mem.eql(u8, name, "Debugger.evaluateOnCallFrame")) return .evaluate_on_call_frame;
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

fn translateParams(allocator: Allocator, method: []const u8, params: std.json.Value) !?std.json.Value {
    if (params != .object) return null;
    const source = params.object;
    if (std.mem.eql(u8, method, "Debugger.setBreakpointByUrl") or std.mem.eql(u8, method, "Debugger.setBreakpoint")) {
        var filtered = std.json.ObjectMap{};
        var iterator = source.iterator();
        while (iterator.next()) |entry| filtered.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch {};
        if (source.get("condition")) |condition| {
            var options = std.json.ObjectMap{};
            options.put(allocator, "condition", condition) catch {};
            filtered.put(allocator, "options", .{ .object = options }) catch {};
            _ = filtered.swapRemove("condition");
        }
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
        return .{ .object = filtered };
    }
    return .{ .object = source };
}

fn scriptUrl(self: *Bridge, script_id: []const u8) ?[]const u8 {
    return self.scripts.get(script_id);
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
    const owned = self.allocator.dupe(u8, url) catch return;
    if (self.scripts.fetchPut(self.allocator, script_id, owned) catch null) |previous| self.allocator.free(previous.value);
}

fn postProcessEvent(self: *Bridge, allocator: Allocator, object: std.json.ObjectMap) !std.json.ObjectMap {
    const method = switch (object.get("method") orelse return object) {
        .string => |text| text,
        else => return object,
    };
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
    if (reason == .string and std.mem.eql(u8, reason.string, "Breakpoint")) {
        params.put(allocator, "reason", .{ .string = "other" }) catch {};
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
                if (frame.object.get("url") != null) continue;
                const location = frame.object.get("location") orelse continue;
                if (location != .object) continue;
                const script_value = location.object.get("scriptId") orelse continue;
                if (script_value != .string) continue;
                const url = scriptUrl(self, script_value.string) orelse continue;
                frame.object.put(allocator, "url", .{ .string = url }) catch {};
            }
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
        .evaluate, .evaluate_on_call_frame => {
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
