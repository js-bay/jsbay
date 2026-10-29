//! External CDP discovery contracts. These tests use the same loopback HTTP and WebSocket boundary as DevTools, so a dispatcher-only registration is not mistaken for a discoverable protocol capability.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const build_options = @import("build_options");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
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

fn openSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target_id });
    errdefer engine.destroy(id);
    errdefer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream) };
}

fn writeAll(stream: wire.TestStream, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const wrote = std.posix.system.write(stream.handle, bytes.ptr + offset, bytes.len - offset);
        if (wrote < 0) {
            if (std.posix.errno(wrote) == .INTR) continue;
            return error.WriteFailed;
        }
        offset += @intCast(wrote);
    }
}

fn readHttp(alloc: std.mem.Allocator, stream: wire.TestStream) ![]u8 {
    // Loopback sockets use a short SO_RCVTIMEO for WS polling. Treat WouldBlock as
    // "keep waiting" until Content-Length is satisfied, not as EOF (which truncated
    // the ~90KB /json/protocol body into UnexpectedEndOfInput).
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    var header_end: ?usize = null;
    var content_length: ?usize = null;
    var idle: usize = 0;
    while (idle < 200) {
        const count = stream.read(&buf) catch |err| switch (err) {
            error.WouldBlock => {
                idle += 1;
                for (0..64) |_| std.Thread.yield() catch {};
                continue;
            },
            else => 0,
        };
        if (count == 0) {
            if (header_end != null and content_length != null and out.items.len >= header_end.? + 4 + content_length.?) break;
            idle += 1;
            for (0..64) |_| std.Thread.yield() catch {};
            continue;
        }
        idle = 0;
        try out.appendSlice(alloc, buf[0..count]);
        if (header_end == null) {
            if (std.mem.indexOf(u8, out.items, "\r\n\r\n")) |he| {
                header_end = he;
                const headers = out.items[0..he];
                var lines = std.mem.splitSequence(u8, headers, "\r\n");
                while (lines.next()) |line| {
                    if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                        const raw = std.mem.trim(u8, line["Content-Length:".len..], " \t");
                        content_length = try std.fmt.parseInt(usize, raw, 10);
                        break;
                    }
                }
            }
        }
        if (header_end) |he| {
            if (content_length) |cl| {
                if (out.items.len >= he + 4 + cl) {
                    out.shrinkRetainingCapacity(he + 4 + cl);
                    break;
                }
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

fn send(session: *Session, method: []const u8, params: []const u8, id: i64) !usize {
    const before = session.got.items.len;
    const request = if (params.len == 0)
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method })
    else
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
    defer session.alloc.free(request);
    try wire.writeMaskedText(session.stream, request);
    return before;
}

fn pumpResponse(session: *Session, from: usize, id: i64) ![]const u8 {
    var tries: usize = 0;
    while (tries < 60) : (tries += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, from, id)) return session.got.items[from..];
    }
    return error.TestUnexpectedResult;
}

fn waitForFrame(session: *Session, from: usize, needle: []const u8, spins: usize) !bool {
    var tries: usize = 0;
    while (tries < spins) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[from..], needle) != null) return true;
    }
    return false;
}

fn domainByName(domains: []const std.json.Value, name: []const u8) ?std.json.Value {
    for (domains) |domain| {
        if (domain != .object) continue;
        const field = domain.object.get("domain") orelse continue;
        if (field == .string and std.mem.eql(u8, field.string, name)) return domain;
    }
    return null;
}

fn expectedDomains() []const []const u8 {
    return switch (backend.active_backend) {
        .quickjs_ng => if (build_options.heap_snapshot)
            &.{ "Runtime", "Debugger", "Profiler", "HeapProfiler", "Performance", "Schema" }
        else
            &.{ "Runtime", "Debugger", "Profiler", "Performance", "Schema" },
        .quickjs => if (build_options.heap_snapshot)
            &.{ "Runtime", "Profiler", "HeapProfiler", "Performance", "Schema" }
        else
            &.{ "Runtime", "Profiler", "Performance", "Schema" },
        .jsc => &.{ "Runtime", "Performance", "Schema" },
    };
}

fn hasCommand(domain: std.json.Value, command_name: []const u8) bool {
    if (domain != .object) return false;
    const commands = domain.object.get("commands") orelse return false;
    if (commands != .array) return false;
    for (commands.array.items) |command| {
        if (command != .object) continue;
        const name = command.object.get("name") orelse continue;
        if (name == .string and std.mem.eql(u8, name.string, command_name)) return true;
    }
    return false;
}

fn collectTypes(alloc: std.mem.Allocator, domains: []const std.json.Value, types: *std.StringHashMap(void)) !void {
    for (domains) |domain| {
        if (domain != .object) return error.TestUnexpectedResult;
        const domain_name = domain.object.get("domain") orelse return error.TestUnexpectedResult;
        if (domain_name != .string) return error.TestUnexpectedResult;
        const entries = domain.object.get("types") orelse continue;
        if (entries != .array) return error.TestUnexpectedResult;
        for (entries.array.items) |entry| {
            if (entry != .object) return error.TestUnexpectedResult;
            const type_id = entry.object.get("id") orelse return error.TestUnexpectedResult;
            if (type_id != .string) return error.TestUnexpectedResult;
            const qualified = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ domain_name.string, type_id.string });
            errdefer alloc.free(qualified);
            try types.put(qualified, {});
        }
    }
}

fn verifyRefs(value: std.json.Value, current_domain: []const u8, types: *const std.StringHashMap(void)) !void {
    switch (value) {
        .array => |items| for (items.items) |item| try verifyRefs(item, current_domain, types),
        .object => |object| {
            if (object.get("$ref")) |ref| {
                if (ref != .string) return error.TestUnexpectedResult;
                const qualified = if (std.mem.indexOfScalar(u8, ref.string, '.') != null)
                    ref.string
                else
                    try std.fmt.allocPrint(testing.allocator, "{s}.{s}", .{ current_domain, ref.string });
                defer if (qualified.ptr != ref.string.ptr) testing.allocator.free(qualified);
                try testing.expect(types.contains(qualified));
            }
            var it = object.iterator();
            while (it.next()) |entry| try verifyRefs(entry.value_ptr.*, current_domain, types);
        },
        else => {},
    }
}

test "cdp discovery: HTTP protocol describes only implemented domains with resolvable refs" {
    const alloc = testing.allocator;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const handle = try inspector.start(id, .{ .port = 0, .target_id = "cdp-discovery-protocol" });
    defer inspector.stop(handle);

    const stream = try wire.connect(inspector.boundPort(handle));
    defer stream.close();
    try writeAll(stream, "GET /json/protocol HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    const response = try readHttp(alloc, stream);
    defer alloc.free(response);
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
    const body_at = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.TestUnexpectedResult;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, response[body_at + 4 ..], .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const version = parsed.value.object.get("version") orelse return error.TestUnexpectedResult;
    try testing.expect(version == .object);
    try testing.expectEqualStrings("1", version.object.get("major").?.string);
    try testing.expectEqualStrings("3", version.object.get("minor").?.string);
    const domains_value = parsed.value.object.get("domains") orelse return error.TestUnexpectedResult;
    try testing.expect(domains_value == .array);
    const domains = domains_value.array.items;
    try testing.expectEqual(expectedDomains().len, domains.len);
    for (expectedDomains()) |name| {
        try testing.expect(domainByName(domains, name) != null);
    }
    try testing.expect(domainByName(domains, "DOM") == null);
    try testing.expect(hasCommand(domainByName(domains, "Runtime").?, "evaluate"));
    try testing.expect(hasCommand(domainByName(domains, "Performance").?, "getMetrics"));
    try testing.expect(hasCommand(domainByName(domains, "Schema").?, "getDomains"));
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        try testing.expect(hasCommand(domainByName(domains, "Runtime").?, "awaitPromise"));
        try testing.expect(hasCommand(domainByName(domains, "Profiler").?, "setSamplingInterval"));
        if (comptime build_options.heap_snapshot) {
            try testing.expect(hasCommand(domainByName(domains, "HeapProfiler").?, "takeHeapSnapshot"));
        } else {
            try testing.expect(domainByName(domains, "HeapProfiler") == null);
        }
    } else {
        try testing.expect(!hasCommand(domainByName(domains, "Runtime").?, "awaitPromise"));
    }
    if (comptime backend.active_backend == .quickjs_ng) {
        try testing.expect(hasCommand(domainByName(domains, "Debugger").?, "setBreakpointByUrl"));
    }

    var types = std.StringHashMap(void).init(alloc);
    defer {
        var it = types.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        types.deinit();
    }
    try collectTypes(alloc, domains, &types);
    for (domains) |domain| {
        const name = domain.object.get("domain").?.string;
        try verifyRefs(domain, name, &types);
    }
}

test "cdp discovery: Schema.getDomains matches HTTP protocol capabilities" {
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-discovery-schema");
    defer session.deinit();
    const from = try send(&session, "Schema.getDomains", "", 1);
    const response = try pumpResponse(&session, from, 1);
    try testing.expect(std.mem.indexOf(u8, response, "\"id\":1,\"result\":") != null);
    for (expectedDomains()) |name| {
        const needle = try std.fmt.allocPrint(alloc, "\"name\":\"{s}\"", .{name});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, response, needle) != null);
    }
    try testing.expect(std.mem.indexOf(u8, response, "\"version\":\"1.3\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"DOM\"") == null);
    try testing.expectEqual(expectedDomains().len, std.mem.count(u8, response, "\"name\":"));
}

test "cdp regression: heap snapshot disabled hides HeapProfiler from HTTP protocol and Schema" {
    if (comptime !build_options.inspector or build_options.heap_snapshot) return error.SkipZigTest;
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-heap-snapshot-discovery");
    defer session.deinit();

    const http = try wire.connect(inspector.boundPort(session.handle));
    defer http.close();
    try writeAll(http, "GET /json/protocol HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    const protocol = try readHttp(alloc, http);
    defer alloc.free(protocol);
    try testing.expect(std.mem.startsWith(u8, protocol, "HTTP/1.1 200 OK"));
    const http_advertises_heap = std.mem.indexOf(u8, protocol, "\"domain\": \"HeapProfiler\"") != null or
        std.mem.indexOf(u8, protocol, "\"domain\":\"HeapProfiler\"") != null;

    const from = try send(&session, "Schema.getDomains", "", 41);
    const schema = try pumpResponse(&session, from, 41);
    const schema_advertises_heap = std.mem.indexOf(u8, schema, "\"name\":\"HeapProfiler\"") != null or
        std.mem.indexOf(u8, schema, "\"name\": \"HeapProfiler\"") != null;
    std.debug.print("R1_F4_HTTP_HEAP={any} SCHEMA_HEAP={any}\n", .{ http_advertises_heap, schema_advertises_heap });
    try testing.expect(!http_advertises_heap and !schema_advertises_heap);
}

test "cdp discovery: engine destruction announces Runtime.executionContextDestroyed" {
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-discovery-context-destroyed");
    defer session.deinit();

    const enabled_from = try send(&session, "Runtime.enable", "", 10);
    _ = try pumpResponse(&session, enabled_from, 10);
    const destroyed_from = session.got.items.len;
    engine.destroy(session.id);
    try testing.expect(try waitForFrame(&session, destroyed_from, "Runtime.executionContextDestroyed", 40));
    const event = session.got.items[destroyed_from..];
    try testing.expect(std.mem.indexOf(u8, event, "\"executionContextId\":1") != null);
}
