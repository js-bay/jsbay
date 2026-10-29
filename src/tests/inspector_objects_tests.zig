//! Integration tests for Wave 8a: rich object inspection (objectId-based remote object handles, Runtime.getProperties, Runtime.callFunctionOn, Runtime.releaseObject{,Group}).
//!
//! Style matches `inspector_tests.zig`: spin up an engine, start the inspector, drive a minimal WebSocket client, and pump `dispatch.tickInstance` while waiting for responses because the evaluate/getProperties/callFunctionOn handlers marshal onto the JS thread via dispatch.postTask.

const std = @import("std");
const io = @import("../platform/io.zig");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const dispatch = @import("../runtime/dispatch.zig");
const inspector = @import("../inspector/root.zig");
const helpers = @import("test_helpers.zig");

// ---------------------------------------------------------------------------
// Minimal WebSocket client helpers — mirrored from inspector_tests.zig so this file is self-contained and doesn't introduce cross-file coupling.
// ---------------------------------------------------------------------------

const TestStream = struct {
    handle: std.posix.fd_t,

    fn read(s: TestStream, buf: []u8) !usize {
        return std.posix.read(s.handle, buf);
    }

    fn writeAll(s: TestStream, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.posix.system.write(s.handle, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            off += @intCast(n);
        }
    }

    fn close(s: TestStream) void {
        _ = std.posix.system.close(s.handle);
    }
};

fn connectLoopback(port: u16) !TestStream {
    const raw_fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw_fd < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw_fd);
    errdefer _ = std.posix.system.close(fd);
    var addr: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };
    if (std.posix.system.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.ConnectFailed;
    return .{ .handle = fd };
}

fn connect(port: u16) !TestStream {
    const stream = try connectLoopback(port);
    var tv: std.posix.timeval = .{ .sec = 0, .usec = 50_000 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
    return stream;
}

fn readHttpHeaders(alloc: std.mem.Allocator, stream: TestStream) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [1]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) return error.EndOfStream;
        try list.append(alloc, buf[0]);
        if (list.items.len >= 4) {
            const tail = list.items[list.items.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) break;
        }
    }
    return list.toOwnedSlice(alloc);
}

fn readAtLeast(stream: TestStream, buf: []u8, need: usize) !usize {
    var got: usize = 0;
    while (got < need) {
        const n = try stream.read(buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    return got;
}

fn writeMaskedText(stream: TestStream, text: []const u8) !void {
    var header: [14]u8 = undefined;
    var hlen: usize = 0;
    header[0] = 0x80 | 0x1;
    if (text.len <= 125) {
        header[1] = 0x80 | @as(u8, @intCast(text.len));
        hlen = 2;
    } else if (text.len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @as(u16, @intCast(text.len)), .big);
        hlen = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], @as(u64, text.len), .big);
        hlen = 10;
    }
    const mask_key: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    @memcpy(header[hlen..][0..4], &mask_key);
    hlen += 4;
    try stream.writeAll(header[0..hlen]);

    var masked_buf: [1024]u8 = undefined;
    var off: usize = 0;
    while (off < text.len) {
        const chunk = @min(masked_buf.len, text.len - off);
        for (0..chunk) |i| {
            masked_buf[i] = text[off + i] ^ mask_key[(off + i) & 3];
        }
        try stream.writeAll(masked_buf[0..chunk]);
        off += chunk;
    }
}

const Frame = struct {
    opcode: u8,
    payload: []u8,
};

fn readFrameTimed(
    alloc: std.mem.Allocator,
    stream: TestStream,
    timeout_ms: u64,
) !?Frame {
    const start = io.milliTimestamp();
    var hdr: [2]u8 = undefined;
    while (true) {
        const elapsed: u64 = @intCast(io.milliTimestamp() - start);
        if (elapsed >= timeout_ms) return null;
        const n = stream.read(hdr[0..1]) catch {
            return null;
        };
        if (n == 1) break;
        io.sleepMs(5);
    }
    _ = try readAtLeast(stream, hdr[1..], 1);
    const opcode: u8 = hdr[0] & 0x0F;
    const masked = (hdr[1] & 0x80) != 0;
    var plen: u64 = hdr[1] & 0x7F;
    if (plen == 126) {
        var ext: [2]u8 = undefined;
        _ = try readAtLeast(stream, &ext, 2);
        plen = std.mem.readInt(u16, &ext, .big);
    } else if (plen == 127) {
        var ext: [8]u8 = undefined;
        _ = try readAtLeast(stream, &ext, 8);
        plen = std.mem.readInt(u64, &ext, .big);
    }
    try testing.expect(!masked);
    const payload = try alloc.alloc(u8, @as(usize, @intCast(plen)));
    if (plen > 0) _ = try readAtLeast(stream, payload, payload.len);
    return .{ .opcode = opcode, .payload = payload };
}

fn doWsHandshake(alloc: std.mem.Allocator, stream: TestStream, target_id: []const u8) !void {
    const req = try std.fmt.allocPrint(
        alloc,
        "GET /{s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{target_id},
    );
    defer alloc.free(req);
    try stream.writeAll(req);

    const hdrs = try readHttpHeaders(alloc, stream);
    defer alloc.free(hdrs);
    try testing.expect(std.mem.startsWith(u8, hdrs, "HTTP/1.1 101"));
}

/// Pump JS thread + wait for the next text frame whose payload contains `needle`. Caller owns the returned payload.
fn waitForReply(
    alloc: std.mem.Allocator,
    instance_id: i32,
    stream: TestStream,
    needle: []const u8,
    timeout_ms: u64,
) !?Frame {
    const deadline = io.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (io.milliTimestamp() < deadline) {
        _ = dispatch.tickInstance(instance_id);
        const frame_opt = try readFrameTimed(alloc, stream, 50);
        if (frame_opt) |frame| {
            if (frame.opcode == 0x1 and std.mem.indexOf(u8, frame.payload, needle) != null) {
                return frame;
            }
            alloc.free(frame.payload);
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tiny JSON dive helper — finds the first `"objectId":"N"` in a payload and returns N as u64. Avoids a full JSON parse for every assertion.
// ---------------------------------------------------------------------------

fn extractObjectId(payload: []const u8) ?u64 {
    // Look for the first `"objectId":"` in the payload.
    const needle = "\"objectId\":\"";
    const idx = std.mem.indexOf(u8, payload, needle) orelse return null;
    const start = idx + needle.len;
    var end = start;
    while (end < payload.len and payload[end] != '"') : (end += 1) {}
    if (end == start or end >= payload.len) return null;
    return std.fmt.parseInt(u64, payload[start..end], 10) catch null;
}

/// Count occurrences of `needle` in `hay`.
fn countOf(hay: []const u8, needle: []const u8) usize {
    var c: usize = 0;
    var i: usize = 0;
    while (i < hay.len) {
        const r = std.mem.indexOfPos(u8, hay, i, needle) orelse break;
        c += 1;
        i = r + needle.len;
    }
    return c;
}

// ---------------------------------------------------------------------------
// Fixture: open WS session on a fresh inspector target.
// ---------------------------------------------------------------------------

const Session = struct {
    id: i32,
    stream: TestStream,
    handle: *inspector.Handle,

    fn send(self: Session, text: []const u8) !void {
        try writeMaskedText(self.stream, text);
    }

    fn wait(
        self: Session,
        alloc: std.mem.Allocator,
        needle: []const u8,
        timeout_ms: u64,
    ) !Frame {
        const opt = try waitForReply(alloc, self.id, self.stream, needle, timeout_ms);
        return opt orelse return error.ResponseTimeout;
    }

    fn close(self: Session) void {
        self.stream.close();
        inspector.stop(self.handle);
        engine.destroy(self.id);
    }
};

fn openSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    errdefer engine.destroy(id);

    const handle = try inspector.start(id, .{
        .port = 0,
        .target_id = target_id,
    });
    errdefer inspector.stop(handle);

    const stream = try connect(inspector.boundPort(handle));
    errdefer stream.close();
    try doWsHandshake(alloc, stream, target_id);

    return .{ .id = id, .stream = stream, .handle = handle };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "inspector: Runtime.evaluate on object returns objectId + className" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-1");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({a:1, b:2})\"}}");
    const frame = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(frame.payload);

    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"className\":\"Object\"") != null);
    try testing.expect(extractObjectId(frame.payload) != null);
}

test "inspector: Runtime.evaluate returnByValue serializes nested object and array without objectId" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-value");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({nested:{answer:42}, items:[true,null,'ok']})\",\"returnByValue\":true}}");
    const frame = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(frame.payload);

    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"value\":{\"nested\":{\"answer\":42},\"items\":[true,null,\"ok\"]}") != null);
    try testing.expect(extractObjectId(frame.payload) == null);
}

test "inspector: Runtime.evaluate false returnByValue keeps an expandable object reference" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-reference");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({answer:42})\",\"returnByValue\":false}}");
    const evaluation = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(evaluation.payload);
    const object_id = extractObjectId(evaluation.payload) orelse return error.NoObjectId;

    const request = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":2,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{object_id},
    );
    defer alloc.free(request);
    try s.send(request);
    const properties = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(properties.payload);
    try testing.expect(std.mem.indexOf(u8, properties.payload, "\"name\":\"answer\"") != null);
    try testing.expect(std.mem.indexOf(u8, properties.payload, "\"value\":42") != null);
}

test "inspector: Runtime.evaluate returnByValue does not invoke toJSON" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-value-to-json");
    defer s.close();

    try s.send(
        "{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"globalThis.__return_by_value_to_json_calls=0; ({a:1,toJSON(){globalThis.__return_by_value_to_json_calls++;return {wrong:true}}})\",\"returnByValue\":true}}",
    );
    const first = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(first.payload);
    try testing.expect(std.mem.indexOf(u8, first.payload, "\"value\":{\"a\":1,\"toJSON\":{}}") != null);

    try s.send("{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"globalThis.__return_by_value_to_json_calls\",\"returnByValue\":true}}");
    const calls = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(calls.payload);
    try testing.expect(std.mem.indexOf(u8, calls.payload, "\"value\":0") != null);
}

test "inspector: Runtime.evaluate rejects non-boolean returnByValue" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-value-invalid");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"42\",\"returnByValue\":\"true\"}}");
    const frame = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(frame.payload);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"code\":-32602") != null);
}

test "inspector: Runtime.evaluate returnByValue follows CDP JSON value edge rules" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-value-json-edges");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({gone:undefined,list:[1,undefined,NaN,Infinity,-0,{n:2}]})\",\"returnByValue\":true}}");
    const object = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(object.payload);
    try testing.expect(std.mem.indexOf(u8, object.payload, "\"value\":{\"list\":[1,null,null,null,0,{\"n\":2}]}") != null);
    try testing.expect(std.mem.indexOf(u8, object.payload, "\"gone\"") == null);

    try s.send("{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"123n\",\"returnByValue\":true}}");
    const bigint = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(bigint.payload);
    try testing.expect(std.mem.indexOf(u8, bigint.payload, "\"type\":\"bigint\"") != null);
    try testing.expect(std.mem.indexOf(u8, bigint.payload, "\"unserializableValue\":\"123n\"") != null);

    try s.send("{\"id\":3,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"-0\",\"returnByValue\":true}}");
    const negative_zero = try s.wait(alloc, "\"id\":3", 3000);
    defer alloc.free(negative_zero.payload);
    try testing.expect(std.mem.indexOf(u8, negative_zero.payload, "\"unserializableValue\":\"-0\"") != null);
}

test "inspector: Runtime.evaluate returnByValue keeps function properties and NUL keys" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-value-function-properties");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"Object.assign(function(){},{a:1, nested:function(){}})\",\"returnByValue\":true}}");
    const function = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(function.payload);
    try testing.expect(std.mem.indexOf(u8, function.payload, "\"type\":\"function\"") != null);
    try testing.expect(std.mem.indexOf(u8, function.payload, "\"value\":{\"a\":1,\"nested\":{}}") != null);

    try s.send("{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({['a\\\\u0000b']:7})\",\"returnByValue\":true}}");
    const nul = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(nul.payload);
    try testing.expect(std.mem.indexOf(u8, nul.payload, "\"a\\u0000b\":7") != null);
}

test "inspector: Runtime.evaluate returnByValue reports getter failures and recovers" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-value-getter-failure");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({get x(){throw new Error('boom')}})\",\"returnByValue\":true}}");
    const failed = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(failed.payload);
    try testing.expect(std.mem.indexOf(u8, failed.payload, "Internal error") != null);

    try s.send("{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"42\",\"returnByValue\":true}}");
    const recovered = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(recovered.payload);
    try testing.expect(std.mem.indexOf(u8, recovered.payload, "\"value\":42") != null);
}

test "inspector: Runtime.evaluate returnByValue rejects unsupported and cyclic values then recovers" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-evaluate-return-by-value-errors");
    defer s.close();

    const cases = [_]struct { id: u8, expression: []const u8, message: []const u8, code: []const u8 }{
        .{ .id = 1, .expression = "(() => { const value = {}; value.self = value; return value; })()", .message = "Object reference chain is too long", .code = "\"code\":-32000" },
        .{ .id = 2, .expression = "({value:123n})", .message = "Object couldn't be returned by value", .code = "\"code\":-32000" },
        .{ .id = 3, .expression = "({value:Symbol('x')})", .message = "Object couldn't be returned by value", .code = "\"code\":-32000" },
        .{ .id = 4, .expression = "new Proxy({}, {ownKeys(){throw new Error('boom')}})", .message = "Internal error", .code = "\"code\":-32603" },
    };
    for (cases) |case| {
        const request = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":{d},\"method\":\"Runtime.evaluate\",\"params\":{{\"expression\":\"{s}\",\"returnByValue\":true}}}}",
            .{ case.id, case.expression },
        );
        defer alloc.free(request);
        try s.send(request);
        const marker = try std.fmt.allocPrint(alloc, "\"id\":{d}", .{case.id});
        defer alloc.free(marker);
        const response = try s.wait(alloc, marker, 3000);
        defer alloc.free(response.payload);
        try testing.expect(std.mem.indexOf(u8, response.payload, case.message) != null);
        try testing.expect(std.mem.indexOf(u8, response.payload, case.code) != null);
    }

    try s.send("{\"id\":5,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"42\",\"returnByValue\":true}}");
    const recovered = try s.wait(alloc, "\"id\":5", 3000);
    defer alloc.free(recovered.payload);
    try testing.expect(std.mem.indexOf(u8, recovered.payload, "\"value\":42") != null);
}

test "inspector: returnByValue rejects a primitive leaf at the 1000-value depth limit" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-return-by-value-depth-limit");
    defer s.close();

    const expression = "(()=>{let r={},p=r;for(let i=0;i<999;i++)p=p.next={};p.value=1;return r})()";
    const requests = [_]struct { id: u8, method: []const u8, params: []const u8 }{
        .{ .id = 1, .method = "Runtime.evaluate", .params = "{\"expression\":\"(()=>{let r={},p=r;for(let i=0;i<999;i++)p=p.next={};p.value=1;return r})()\",\"returnByValue\":true}" },
        .{ .id = 2, .method = "Runtime.callFunctionOn", .params = "{\"functionDeclaration\":\"function(){return (()=>{let r={},p=r;for(let i=0;i<999;i++)p=p.next={};p.value=1;return r})()}\",\"returnByValue\":true}" },
    };
    _ = expression;
    for (requests) |request| {
        const wire = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ request.id, request.method, request.params });
        defer alloc.free(wire);
        try s.send(wire);
        const marker = try std.fmt.allocPrint(alloc, "\"id\":{d}", .{request.id});
        defer alloc.free(marker);
        const response = try s.wait(alloc, marker, 3000);
        defer alloc.free(response.payload);
        try testing.expect(std.mem.indexOf(u8, response.payload, "Object reference chain is too long") != null);
    }

    try s.send("{\"id\":3,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"42\",\"returnByValue\":true}}");
    const recovered = try s.wait(alloc, "\"id\":3", 3000);
    defer alloc.free(recovered.payload);
    try testing.expect(std.mem.indexOf(u8, recovered.payload, "\"value\":42") != null);
}

test "inspector: returnByValue serializes a 999-value object chain" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-return-by-value-depth-success");
    defer s.close();

    const requests = [_]struct { id: u8, method: []const u8, params: []const u8 }{
        .{ .id = 1, .method = "Runtime.evaluate", .params = "{\"expression\":\"(()=>{let r={},p=r;for(let i=0;i<998;i++)p=p.next={};p.value=1;return r})()\",\"returnByValue\":true}" },
        .{ .id = 2, .method = "Runtime.callFunctionOn", .params = "{\"functionDeclaration\":\"function(){return (()=>{let r={},p=r;for(let i=0;i<998;i++)p=p.next={};p.value=1;return r})()}\",\"returnByValue\":true}" },
    };
    for (requests) |request| {
        const wire = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ request.id, request.method, request.params });
        defer alloc.free(wire);
        try s.send(wire);
        const marker = try std.fmt.allocPrint(alloc, "\"id\":{d}", .{request.id});
        defer alloc.free(marker);
        const response = try s.wait(alloc, marker, 3000);
        defer alloc.free(response.payload);
        try testing.expect(std.mem.indexOf(u8, response.payload, "\"value\":1") != null);
        try testing.expect(std.mem.indexOf(u8, response.payload, "\"error\"") == null);
    }
}

const ByValueFailWriter = struct {
    fail_at_byte: usize,
    byte_calls: usize = 0,

    fn fail(self: *ByValueFailWriter) error{WriterFailure}!void {
        self.byte_calls += 1;
        if (self.byte_calls == self.fail_at_byte) return error.WriterFailure;
    }

    pub fn writeAll(_: *ByValueFailWriter, _: []const u8) error{WriterFailure}!void {}

    pub fn writeByte(self: *ByValueFailWriter, _: u8) error{WriterFailure}!void {
        try self.fail();
    }

    pub fn print(self: *ByValueFailWriter, comptime _: []const u8, _: anytype) error{WriterFailure}!void {
        try self.fail();
    }
};

fn expectByValueWriterFailure(fail_at_byte: usize) !void {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-return-by-value-writer-failure");
    defer s.close();

    const ctx = engine.getContext(s.id) orelse return error.NoContext;
    const raw = engine.evalScriptTyped(s.id, "({key:{nested:1}})", "writer-failure.js") orelse return error.NoTypedResult;
    defer if (raw.exception) |exception| backend.ActiveEngine.freeValue(ctx, exception);
    const value = raw.value orelse return error.NoTypedValue;
    defer backend.ActiveEngine.freeValue(ctx, value);
    const state: *inspector.state.InspectorState = @ptrCast(@alignCast(s.handle));

    var writer = ByValueFailWriter{ .fail_at_byte = fail_at_byte };
    try testing.expectError(error.WriterFailure, inspector.remote_object.writeRemoteObjectByValue(state, ctx, &writer, value));

    try helpers.expectEvalEquals(s.id, "1 + 1", "2");
}

test "inspector: returnByValue releases Object.keys when the opening writer byte fails" {
    // The first byte emitted by the iterative serializer is the object's `{`, after Object.keys has returned but before its value enters the frame.
    try expectByValueWriterFailure(1);
}

test "inspector: returnByValue releases Reflect.get child when the key writer byte fails" {
    // The second byte is the first key quote, after Reflect.get has returned a child but before that child becomes a frame-owned value.
    try expectByValueWriterFailure(2);
}

test "inspector: Runtime.getProperties returns own props with nested objectId" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-getprops-1");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({a:1, b:[2,3]})\"}}");
    const ev = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(ev.payload);
    const oid = extractObjectId(ev.payload) orelse return error.NoObjectId;

    const req = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":2,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{oid},
    );
    defer alloc.free(req);
    try s.send(req);
    const gp = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(gp.payload);

    try testing.expect(std.mem.indexOf(u8, gp.payload, "\"name\":\"a\"") != null);
    try testing.expect(std.mem.indexOf(u8, gp.payload, "\"name\":\"b\"") != null);
    // `a` is a primitive number 1.
    try testing.expect(std.mem.indexOf(u8, gp.payload, "\"type\":\"number\",\"value\":1") != null);
    // `b` is an object (array) and must carry a distinct objectId.
    try testing.expect(std.mem.indexOf(u8, gp.payload, "\"subtype\":\"array\"") != null);
    // Two objectIds in the payload: one per retained value that was an object/array. (The root's own id was retained by evaluate too, but isn't referenced in the getProperties reply.)
    try testing.expect(extractObjectId(gp.payload) != null);
}

test "inspector: nested getProperties follows a returned objectId" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-getprops-nested");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({arr:[10,20,30]})\"}}");
    const ev = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(ev.payload);
    const outer_id = extractObjectId(ev.payload) orelse return error.NoOuterId;

    const req1 = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":2,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{outer_id},
    );
    defer alloc.free(req1);
    try s.send(req1);
    const gp1 = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(gp1.payload);
    const arr_id = extractObjectId(gp1.payload) orelse return error.NoArrayId;
    try testing.expect(arr_id != outer_id);

    const req2 = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":3,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{arr_id},
    );
    defer alloc.free(req2);
    try s.send(req2);
    const gp2 = try s.wait(alloc, "\"id\":3", 3000);
    defer alloc.free(gp2.payload);

    // Elements 0, 1, 2 with numeric values.
    try testing.expect(std.mem.indexOf(u8, gp2.payload, "\"name\":\"0\"") != null);
    try testing.expect(std.mem.indexOf(u8, gp2.payload, "\"name\":\"2\"") != null);
    try testing.expect(std.mem.indexOf(u8, gp2.payload, "\"value\":30") != null);
}

test "inspector: Runtime.releaseObject frees the handle" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-release-1");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({x:1})\"}}");
    const ev = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(ev.payload);
    const oid = extractObjectId(ev.payload) orelse return error.NoObjectId;

    const rel = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":2,\"method\":\"Runtime.releaseObject\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{oid},
    );
    defer alloc.free(rel);
    try s.send(rel);
    const rel_reply = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(rel_reply.payload);
    try testing.expect(std.mem.indexOf(u8, rel_reply.payload, "\"result\":{}") != null);

    const gp = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":3,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{oid},
    );
    defer alloc.free(gp);
    try s.send(gp);
    const err_reply = try s.wait(alloc, "\"id\":3", 3000);
    defer alloc.free(err_reply.payload);
    try testing.expect(std.mem.indexOf(u8, err_reply.payload, "\"code\":-32000") != null);
    try testing.expect(std.mem.indexOf(u8, err_reply.payload, "Could not find object") != null);
}

test "inspector: Runtime.callFunctionOn binds this to objectId" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-call-1");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({x:10})\"}}");
    const ev = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(ev.payload);
    const oid = extractObjectId(ev.payload) orelse return error.NoObjectId;

    const call = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":2,\"method\":\"Runtime.callFunctionOn\",\"params\":{{\"objectId\":\"{d}\",\"functionDeclaration\":\"function(){{ return this.x * 2; }}\"}}}}",
        .{oid},
    );
    defer alloc.free(call);
    try s.send(call);
    const reply = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(reply.payload);

    try testing.expect(std.mem.indexOf(u8, reply.payload, "\"type\":\"number\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply.payload, "\"value\":20") != null);
}

test "inspector: Runtime.callFunctionOn returnByValue serializes object result without objectId" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-call-return-by-value");
    defer s.close();

    try s.send(
        "{\"id\":1,\"method\":\"Runtime.callFunctionOn\",\"params\":{\"functionDeclaration\":\"function(){ return {answer:42, items:[1,2]}; }\",\"returnByValue\":true}}",
    );
    const frame = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(frame.payload);

    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"value\":{\"answer\":42,\"items\":[1,2]}") != null);
    try testing.expect(extractObjectId(frame.payload) == null);
}

test "inspector: Runtime.callFunctionOn passes primitive value arguments" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-call-2");
    defer s.close();

    try s.send(
        "{\"id\":1,\"method\":\"Runtime.callFunctionOn\",\"params\":{\"functionDeclaration\":\"function(a){ return a + 1; }\",\"arguments\":[{\"value\":41}]}}",
    );
    const reply = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(reply.payload);

    try testing.expect(std.mem.indexOf(u8, reply.payload, "\"type\":\"number\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply.payload, "\"value\":42") != null);
}

test "inspector: Runtime.callFunctionOn passes objectId arguments" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-call-3");
    defer s.close();

    // Evaluate two objects. Use distinct `id`s so the replies don't collide.
    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({name:'left'})\"}}");
    const ev1 = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(ev1.payload);
    const this_id = extractObjectId(ev1.payload) orelse return error.NoThisId;

    try s.send("{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({name:'right'})\"}}");
    const ev2 = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(ev2.payload);
    const other_id = extractObjectId(ev2.payload) orelse return error.NoOtherId;
    try testing.expect(other_id != this_id);

    const call = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":3,\"method\":\"Runtime.callFunctionOn\",\"params\":{{\"objectId\":\"{d}\",\"functionDeclaration\":\"function(other){{ return this.name + '-' + other.name; }}\",\"arguments\":[{{\"objectId\":\"{d}\"}}]}}}}",
        .{ this_id, other_id },
    );
    defer alloc.free(call);
    try s.send(call);
    const reply = try s.wait(alloc, "\"id\":3", 3000);
    defer alloc.free(reply.payload);

    try testing.expect(std.mem.indexOf(u8, reply.payload, "\"type\":\"string\"") != null);
    try testing.expect(std.mem.indexOf(u8, reply.payload, "left-right") != null);
}

test "inspector: Runtime.releaseObjectGroup frees every member" {
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-group-1");
    defer s.close();

    // Evaluate two objects into the same group.
    try s.send("{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({k:1})\",\"objectGroup\":\"g\"}}");
    const ev1 = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(ev1.payload);
    const oid1 = extractObjectId(ev1.payload) orelse return error.NoObjectId1;

    try s.send("{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({k:2})\",\"objectGroup\":\"g\"}}");
    const ev2 = try s.wait(alloc, "\"id\":2", 3000);
    defer alloc.free(ev2.payload);
    const oid2 = extractObjectId(ev2.payload) orelse return error.NoObjectId2;
    try testing.expect(oid1 != oid2);

    // Release the group.
    try s.send("{\"id\":3,\"method\":\"Runtime.releaseObjectGroup\",\"params\":{\"objectGroup\":\"g\"}}");
    const rel = try s.wait(alloc, "\"id\":3", 3000);
    defer alloc.free(rel.payload);
    try testing.expect(std.mem.indexOf(u8, rel.payload, "\"result\":{}") != null);

    // Both ids now return "not found".
    const q1 = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":4,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{oid1},
    );
    defer alloc.free(q1);
    try s.send(q1);
    const gp1 = try s.wait(alloc, "\"id\":4", 3000);
    defer alloc.free(gp1.payload);
    try testing.expect(std.mem.indexOf(u8, gp1.payload, "\"code\":-32000") != null);

    const q2 = try std.fmt.allocPrint(
        alloc,
        "{{\"id\":5,\"method\":\"Runtime.getProperties\",\"params\":{{\"objectId\":\"{d}\"}}}}",
        .{oid2},
    );
    defer alloc.free(q2);
    try s.send(q2);
    const gp2 = try s.wait(alloc, "\"id\":5", 3000);
    defer alloc.free(gp2.payload);
    try testing.expect(std.mem.indexOf(u8, gp2.payload, "\"code\":-32000") != null);
}

test "inspector: getProperties on primitive string objectId is rejected" {
    // Sanity check that a nonexistent id reports not-found rather than crashing.
    const alloc = testing.allocator;
    const s = try openSession(alloc, "objects-missing-1");
    defer s.close();

    try s.send("{\"id\":1,\"method\":\"Runtime.getProperties\",\"params\":{\"objectId\":\"99999\"}}");
    const reply = try s.wait(alloc, "\"id\":1", 3000);
    defer alloc.free(reply.payload);
    try testing.expect(std.mem.indexOf(u8, reply.payload, "\"code\":-32000") != null);
    try testing.expectEqual(@as(usize, 1), countOf(reply.payload, "\"id\":1"));
}
