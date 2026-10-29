//! CDP Runtime.getProperties for accessors, non-enumerable own data, and the prototype chain. QuickJS only. Session flow matches cdp_reference_tests.zig: open a WebSocket, enable Runtime, evaluate an object, then getProperties.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
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
    got: std.ArrayList(u8),
    next_id: i64 = 1,

    fn deinit(self: *Session) void {
        self.reader.deinit(self.alloc);
        self.stream.close();
        inspector.stop(self.handle);
        engine.destroy(self.id);
        self.got.deinit(self.alloc);
    }

    fn command(self: *Session, method: []const u8, params: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;
        const text = if (params.len == 0)
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method })
        else
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
        defer self.alloc.free(text);
        try wire.writeMaskedText(self.stream, text);
        return id;
    }

    fn wait(self: *Session, needle: []const u8, spins: usize) !bool {
        return self.waitFrom(0, needle, spins);
    }

    fn waitFrom(self: *Session, start: usize, needle: []const u8, spins: usize) !bool {
        var i: usize = 0;
        while (i < spins) : (i += 1) {
            // Runtime.evaluate / getProperties run on the JS queue. The test thread has to drain it; nothing else is pumping.
            _ = dispatch.tickInstance(self.id);
            try wire.readTextFrames(self.alloc, &self.reader, &self.got, 1);
            const region = if (start < self.got.items.len) self.got.items[start..] else "";
            if (std.mem.indexOf(u8, region, needle) != null) return true;
        }
        return false;
    }

    fn expect(self: *Session, ok: bool) !void {
        if (ok) return;
        std.debug.print("cdp bytes:\n{s}\n", .{self.got.items});
        return error.TestUnexpectedResult;
    }
};

fn openSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    return openSessionWithPreStartScript(alloc, target_id, null);
}

fn openSessionWithPreStartScript(alloc: std.mem.Allocator, target_id: []const u8, pre_start_script: ?[]const u8) !Session {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    if (pre_start_script) |script| {
        const ran = engine.evalScript(id, script, "pre-inspector.js");
        if (ran.result) |text| std.heap.c_allocator.free(text);
        if (ran.err) |text| std.heap.c_allocator.free(text);
    }
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target_id });
    errdefer engine.destroy(id);
    errdefer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{
        .alloc = alloc,
        .id = id,
        .handle = handle,
        .stream = stream,
        .reader = wire.FrameReader.init(stream),
        .got = .empty,
    };
}

fn idMarker(alloc: std.mem.Allocator, id: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "\"id\":{d},", .{id});
}

fn quoteAfter(text: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

fn enableRuntime(session: *Session) !void {
    const id = try session.command("Runtime.enable", "");
    const marker = try idMarker(session.alloc, id);
    defer session.alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
}

fn evaluateObject(session: *Session, expression: []const u8) ![]u8 {
    const params = try std.fmt.allocPrint(session.alloc, "{{\"expression\":\"{s}\"}}", .{expression});
    defer session.alloc.free(params);
    const id = try session.command("Runtime.evaluate", params);
    const marker = try idMarker(session.alloc, id);
    defer session.alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
    const at = std.mem.indexOf(u8, session.got.items, marker).?;
    const oid = quoteAfter(session.got.items[at..], "\"objectId\":") orelse {
        std.debug.print("evaluate reply:\n{s}\n", .{session.got.items[at..]});
        return error.TestUnexpectedResult;
    };
    return session.alloc.dupe(u8, oid);
}

/// Returns the index in `session.got` where this command's reply starts.
fn getPropertiesAt(session: *Session, object_id: []const u8, own_properties: ?bool) !usize {
    return getPropertiesExtra(session, object_id, own_properties, "");
}

fn getPropertiesExtra(session: *Session, object_id: []const u8, own_properties: ?bool, extra: []const u8) !usize {
    const params = if (own_properties) |flag|
        try std.fmt.allocPrint(session.alloc, "{{\"objectId\":\"{s}\",\"ownProperties\":{}{s}}}", .{ object_id, flag, extra })
    else
        try std.fmt.allocPrint(session.alloc, "{{\"objectId\":\"{s}\"{s}}}", .{ object_id, extra });
    defer session.alloc.free(params);
    const before = session.got.items.len;
    const id = try session.command("Runtime.getProperties", params);
    const marker = try idMarker(session.alloc, id);
    defer session.alloc.free(marker);
    try session.expect(try session.waitFrom(before, marker, 40));
    return std.mem.indexOfPos(u8, session.got.items, before, marker).?;
}

fn expectHas(region: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, region, needle) != null) return;
    std.debug.print("missing {s} in:\n{s}\n", .{ needle, region });
    return error.TestUnexpectedResult;
}

fn expectLacks(region: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, region, needle) == null) return;
    std.debug.print("unexpected {s} in:\n{s}\n", .{ needle, region });
    return error.TestUnexpectedResult;
}

fn matchObject(text: []const u8, open: usize) ?[]const u8 {
    if (open >= text.len or text[open] != '{') return null;
    var depth: i32 = 0;
    var i = open;
    var in_str = false;
    var escaped = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_str) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return text[open .. i + 1];
        }
    }
    return null;
}

fn descriptorNamed(payload: []const u8, name: []const u8) ?[]const u8 {
    const key = "\"name\":\"";
    var from: usize = 0;
    while (from < payload.len) {
        const rel = std.mem.indexOf(u8, payload[from..], key) orelse return null;
        const name_at = from + rel + key.len;
        if (name_at + name.len < payload.len and
            std.mem.eql(u8, payload[name_at..][0..name.len], name) and
            payload[name_at + name.len] == '"')
        {
            const attr = from + rel;
            var open = attr;
            while (open > 0 and payload[open] != '{') open -= 1;
            if (payload[open] == '{') {
                if (matchObject(payload, open)) |obj| return obj;
            }
        }
        from = name_at + 1;
    }
    return null;
}

fn requireDescriptor(payload: []const u8, name: []const u8) ![]const u8 {
    return descriptorNamed(payload, name) orelse {
        std.debug.print("no descriptor {s} in:\n{s}\n", .{ name, payload });
        return error.TestUnexpectedResult;
    };
}

test "cdp: Runtime.getProperties reports accessors and non-enumerable own data" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-accessors");
    defer session.deinit();
    try enableRuntime(&session);

    // The getter throws if invoked. A descriptor value of 1, or the error text, means getProperties called it instead of returning `get`.
    const expr = "var o = { get g() { throw new Error('getter ran') }, set s(v) {} }; Object.defineProperty(o, 'hidden', { value: 42, enumerable: false, writable: true, configurable: false }); o";
    const oid = try evaluateObject(&session, expr);
    defer alloc.free(oid);

    const at = try getPropertiesAt(&session, oid, null);
    const reply = session.got.items[at..];
    try expectLacks(reply, "getter ran");

    const getter = try requireDescriptor(reply, "g");
    try expectHas(getter, "\"get\":{\"type\":\"function\"");
    try expectLacks(getter, "\"value\":");
    try expectLacks(getter, "\"writable\":");
    try expectHas(getter, "\"enumerable\":true,\"configurable\":true,\"isOwn\":true");

    const setter = try requireDescriptor(reply, "s");
    try expectHas(setter, "\"set\":{\"type\":\"function\"");
    try expectHas(setter, "\"get\":{\"type\":\"undefined\"}");
    try expectLacks(setter, "\"value\":");
    try expectHas(setter, "\"enumerable\":true,\"configurable\":true,\"isOwn\":true");

    const hidden = try requireDescriptor(reply, "hidden");
    try expectHas(hidden, "\"type\":\"number\",\"value\":42");
    try expectHas(hidden, "\"writable\":true,\"enumerable\":false,\"configurable\":false,\"isOwn\":true");

    const proto = try requireDescriptor(reply, "__proto__");
    try expectHas(proto, "\"type\":\"object\"");
    try expectLacks(proto, "\"subtype\":\"null\"");
    try expectHas(proto, "\"writable\":true,\"enumerable\":false,\"configurable\":true,\"isOwn\":true");
}

test "cdp: Runtime.getProperties includes enumerable prototype names when ownProperties is false" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-proto");
    defer session.deinit();
    try enableRuntime(&session);

    const expr = "var proto = { inherited: 7 }; var o = Object.create(proto); o.own = 3; o";
    const oid = try evaluateObject(&session, expr);
    defer alloc.free(oid);

    const own_at = try getPropertiesAt(&session, oid, null);
    const chain_at = try getPropertiesAt(&session, oid, false);
    const own_reply = session.got.items[own_at..chain_at];
    const chain_reply = session.got.items[chain_at..];

    try expectLacks(own_reply, "\"name\":\"inherited\"");
    const own = try requireDescriptor(own_reply, "own");
    try expectHas(own, "\"type\":\"number\",\"value\":3");
    try expectHas(own, "\"writable\":true,\"enumerable\":true,\"configurable\":true,\"isOwn\":true");
    _ = try requireDescriptor(own_reply, "__proto__");

    const inherited = try requireDescriptor(chain_reply, "inherited");
    try expectHas(inherited, "\"type\":\"number\",\"value\":7");
    try expectHas(inherited, "\"isOwn\":false");
    try expectLacks(inherited, "\"isOwn\":true");
    try expectHas(inherited, "\"enumerable\":true");
    const own_again = try requireDescriptor(chain_reply, "own");
    try expectHas(own_again, "\"isOwn\":true");
    _ = try requireDescriptor(chain_reply, "__proto__");
}

test "cdp: getProperties reports symbol keys and undefined accessors" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-symbol");
    defer session.deinit();
    try enableRuntime(&session);
    const expr = "var o = {}; o[Symbol.for('id')] = 7; Object.defineProperty(o, 'blank', { get: undefined, set: undefined, enumerable: true, configurable: true }); o";
    const oid = try evaluateObject(&session, expr);
    defer alloc.free(oid);
    const at = try getPropertiesAt(&session, oid, null);
    const reply = session.got.items[at..];
    const sym = try requireDescriptor(reply, "Symbol(id)");
    try expectHas(sym, "\"symbol\":{\"type\":\"symbol\"");
    try expectHas(sym, "\"type\":\"number\",\"value\":7");
    const blank = try requireDescriptor(reply, "blank");
    try expectHas(blank, "\"get\":{\"type\":\"undefined\"");
    try expectHas(blank, "\"set\":{\"type\":\"undefined\"");
    try expectLacks(blank, "\"value\":");
}

test "cdp: getProperties honors accessor, index, and preview flags" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-flags");
    defer session.deinit();
    try enableRuntime(&session);
    const expr = "var a = ['x']; a.named = {n:1}; Object.defineProperty(a, 'g', { get: function () { return 1; }, enumerable: true, configurable: true }); a";
    const oid = try evaluateObject(&session, expr);
    defer alloc.free(oid);

    const acc_at = try getPropertiesExtra(&session, oid, null, ",\"accessorPropertiesOnly\":true");
    const acc = session.got.items[acc_at..];
    try expectHas(acc, "\"name\":\"g\"");
    try expectLacks(try requireDescriptor(acc, "g"), "\"value\":");
    // The accessor-only reply must not list the data names.
    const acc_g = try requireDescriptor(acc, "g");
    _ = acc_g;
    try testing.expect(descriptorNamed(acc, "named") == null);
    try testing.expect(descriptorNamed(acc, "0") == null);

    const idx_at = try getPropertiesExtra(&session, oid, null, ",\"nonIndexedPropertiesOnly\":true");
    const idx = session.got.items[idx_at..];
    try testing.expect(descriptorNamed(idx, "0") == null);
    try expectHas(try requireDescriptor(idx, "named"), "\"name\":\"named\"");

    const prev_at = try getPropertiesExtra(&session, oid, null, ",\"generatePreview\":true");
    const named = try requireDescriptor(session.got.items[prev_at..], "named");
    try expectHas(named, "\"preview\":{\"type\":\"object\"");
    try expectHas(named, "\"name\":\"n\"");
}

test "cdp: __proto__ is not writable on a non-extensible object" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-ext");
    defer session.deinit();
    try enableRuntime(&session);
    const oid = try evaluateObject(&session, "var o = {a:1}; Object.preventExtensions(o); o");
    defer alloc.free(oid);
    const at = try getPropertiesAt(&session, oid, null);
    const proto = try requireDescriptor(session.got.items[at..], "__proto__");
    try expectHas(proto, "\"writable\":false");
}

test "cdp: a throwing property descriptor is wasThrown" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-throw");
    defer session.deinit();
    try enableRuntime(&session);
    const expr = "new Proxy({a:1}, { getOwnPropertyDescriptor(t, k) { if (k === 'a') throw new Error('boom'); return Reflect.getOwnPropertyDescriptor(t, k); } })";
    const oid = try evaluateObject(&session, expr);
    defer alloc.free(oid);
    const at = try getPropertiesAt(&session, oid, null);
    const reply = session.got.items[at..];
    const thrown = try requireDescriptor(reply, "a");
    try expectHas(thrown, "\"wasThrown\":true");
    try expectLacks(thrown, "boom");
}

test "cdp: settled promises expose internal state" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-promise");
    defer session.deinit();
    try enableRuntime(&session);
    const oid = try evaluateObject(&session, "Promise.resolve(1)");
    defer alloc.free(oid);
    const at = try getPropertiesAt(&session, oid, null);
    const reply = session.got.items[at..];
    try expectHas(reply, "\"name\":\"[[PromiseState]]\"");
    try expectHas(reply, "\"value\":\"fulfilled\"");
    try expectHas(reply, "\"name\":\"[[PromiseResult]]\"");
}

test "cdp: object preview treats an undefined getter and setter as an accessor" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-preview-accessor");
    defer session.deinit();
    try enableRuntime(&session);
    const expr = "var inner = {}; Object.defineProperty(inner, 'blank', { get: undefined, set: undefined, enumerable: true, configurable: true }); ({ inner: inner })";
    const oid = try evaluateObject(&session, expr);
    defer alloc.free(oid);
    const at = try getPropertiesExtra(&session, oid, null, ",\"generatePreview\":true");
    const blank = try requireDescriptor(session.got.items[at..], "blank");
    try expectHas(blank, "\"type\":\"accessor\"");
    try expectLacks(blank, "\"type\":\"undefined\"");
}

test "cdp: getProperties keeps result and internalProperties in one object" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-envelope");
    defer session.deinit();
    try enableRuntime(&session);
    const oid = try evaluateObject(&session, "({a:1})");
    defer alloc.free(oid);
    const at = try getPropertiesAt(&session, oid, null);
    const reply = session.got.items[at..];
    try expectHas(reply, "],\"internalProperties\":[]}}");
    const result_at = std.mem.indexOf(u8, reply, "\"result\":[") orelse return error.TestUnexpectedResult;
    const internal_at = std.mem.indexOf(u8, reply, "\"internalProperties\":") orelse return error.TestUnexpectedResult;
    try testing.expect(internal_at > result_at);
}

test "cdp: failed duplicate creation cannot replace the original intrinsic snapshot" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const patch = engine.evalScript(id, "Reflect.ownKeys = () => { throw new Error('replacement') };", "duplicate-create.js");
    if (patch.result) |text| std.heap.c_allocator.free(text);
    if (patch.err) |text| std.heap.c_allocator.free(text);
    try testing.expect(!engine.create(id, .{}));

    const handle = try inspector.start(id, .{ .port = 0, .target_id = "cdp-duplicate-create" });
    errdefer inspector.stop(handle);
    errdefer engine.destroy(id);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, "cdp-duplicate-create");
    var session = Session{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream), .got = .empty };
    defer session.deinit();
    try enableRuntime(&session);
    const oid = try evaluateObject(&session, "({ preserved: 42 })");
    defer alloc.free(oid);
    const at = try getPropertiesAt(&session, oid, null);
    try expectHas(try requireDescriptor(session.got.items[at..], "preserved"), "\"type\":\"number\",\"value\":42");
}

test "cdp: getProperties uses original intrinsics when the page patches them before attach" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSessionWithPreStartScript(
        alloc,
        "cdp-props-pre-attach-intrinsics",
        "Reflect.ownKeys = () => { throw new Error('patched ownKeys') }; Object.getOwnPropertyDescriptor = () => { throw new Error('patched descriptor') }; Object.getPrototypeOf = () => { throw new Error('patched prototype') }; Object.prototype.hasOwnProperty = () => { throw new Error('patched hasOwn') };",
    );
    defer session.deinit();
    try enableRuntime(&session);

    const oid = try evaluateObject(&session, "({ preserved: 42 })");
    defer alloc.free(oid);
    const at = try getPropertiesAt(&session, oid, null);
    const reply = session.got.items[at..];
    try expectHas(try requireDescriptor(reply, "preserved"), "\"type\":\"number\",\"value\":42");
}

test "cdp: getProperties keeps working after page replaces reflection intrinsics" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-props-intrinsics");
    defer session.deinit();
    try enableRuntime(&session);

    const oid = try evaluateObject(&session, "({ preserved: 42 })");
    defer alloc.free(oid);

    const ran = engine.evalScript(session.id, "Reflect.ownKeys = () => { throw new Error('patched ownKeys') }; Object.getOwnPropertyDescriptor = () => { throw new Error('patched descriptor') }; Object.getPrototypeOf = () => { throw new Error('patched prototype') }; Object.prototype.hasOwnProperty = () => { throw new Error('patched hasOwn') };", "patch-intrinsics.js");
    if (ran.result) |text| std.heap.c_allocator.free(text);
    if (ran.err) |text| std.heap.c_allocator.free(text);

    const at = try getPropertiesAt(&session, oid, null);
    const reply = session.got.items[at..];
    try expectHas(try requireDescriptor(reply, "preserved"), "\"type\":\"number\",\"value\":42");
}
