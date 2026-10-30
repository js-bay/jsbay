//! Black-box contracts for diagnostic data exposed through the public API.
//!
//! These tests deliberately consume CDP messages over a WebSocket.  They do not import heap/profiler internals: a native or SDK consumer must observe the same capability, accounting, and reference information.

const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const c_api = @import("../c_api.zig");
const build_options = @import("build_options");
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

fn openSession(alloc: std.mem.Allocator, target: []const u8) !Session {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target });
    errdefer engine.destroy(id);
    errdefer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target);
    return .{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream) };
}
fn send(session: *Session, method: []const u8, params: []const u8, id: i64) !void {
    const text = if (params.len == 0)
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method })
    else
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
    defer session.alloc.free(text);
    try wire.writeMaskedText(session.stream, text);
}

fn pumpResponse(session: *Session, id: i64) !void {
    const start = session.got.items.len;
    for (0..80) |_| {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, start, id)) return;
    }
    std.debug.print("missing CDP response {d}:\n{s}\n", .{ id, session.got.items });
    return error.TestUnexpectedResult;
}

fn configureFastProfilerSampling(session: *Session) !void {
    try send(session, "Profiler.setSamplingInterval", "{\"interval\":1}", 0);
    try pumpResponse(session, 0);
}

fn expectUnsupportedResponse(payload: []const u8, id: i64) !void {
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const seen_id = parsed.value.object.get("id") orelse continue;
        if (seen_id != .integer or seen_id.integer != id) continue;
        const failure = parsed.value.object.get("error") orelse return error.TestUnexpectedResult;
        try testing.expect(failure == .object);
        const message = failure.object.get("message") orelse return error.TestUnexpectedResult;
        try testing.expect(message == .string);
        try testing.expect(std.mem.indexOf(u8, message.string, "unsupported") != null);
        return;
    }
    return error.TestUnexpectedResult;
}

fn expectErrorResponse(payload: []const u8, id: i64) !void {
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const seen_id = parsed.value.object.get("id") orelse continue;
        if (seen_id != .integer or seen_id.integer != id) continue;
        try testing.expect(parsed.value.object.get("error") != null);
        try testing.expect(parsed.value.object.get("result") == null);
        return;
    }
    return error.TestUnexpectedResult;
}

fn responseLine(payload: []const u8, id: i64) ![]const u8 {
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const seen_id = parsed.value.object.get("id") orelse continue;
        if (seen_id == .integer and seen_id.integer == id) return line;
    }
    return error.TestUnexpectedResult;
}

fn snapshotPayload(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const method = parsed.value.object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "HeapProfiler.addHeapSnapshotChunk")) continue;
        const params = parsed.value.object.get("params") orelse continue;
        if (params != .object) continue;
        const chunk = params.object.get("chunk") orelse continue;
        if (chunk != .string) continue;
        try out.appendSlice(alloc, chunk.string);
    }
    return out.toOwnedSlice(alloc);
}

fn intAt(values: []const std.json.Value, index: usize) !i64 {
    if (index >= values.len or values[index] != .integer) return error.TestUnexpectedResult;
    return values[index].integer;
}

fn stringAt(values: []const std.json.Value, index: usize) ![]const u8 {
    if (index >= values.len or values[index] != .string) return error.TestUnexpectedResult;
    return values[index].string;
}

fn stringIndex(strings: []const std.json.Value, wanted: []const u8) ?usize {
    for (strings, 0..) |value, i| {
        if (value == .string and std.mem.eql(u8, value.string, wanted)) return i;
    }
    return null;
}

fn hasEdge(edges: []const std.json.Value, kind: i64, name_or_index: i64, target: ?i64) bool {
    var i: usize = 0;
    while (i + 2 < edges.len) : (i += 3) {
        const edge_kind = intAt(edges, i) catch continue;
        if (edge_kind != kind) continue;
        const edge_name = intAt(edges, i + 1) catch continue;
        if (edge_name != name_or_index) continue;
        if (target) |to| {
            const edge_target = intAt(edges, i + 2) catch continue;
            if (edge_target != to) continue;
        }
        return true;
    }
    return false;
}

fn unsignedField(payload: []const u8, key: []const u8) !u64 {
    const at = std.mem.indexOf(u8, payload, key) orelse return error.TestUnexpectedResult;
    const rest = payload[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return error.TestUnexpectedResult;
    return std.fmt.parseInt(u64, rest[0..end], 10);
}

fn expectInvalidParams(payload: []const u8, id: i64) !void {
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const seen_id = parsed.value.object.get("id") orelse continue;
        if (seen_id != .integer or seen_id.integer != id) continue;
        const failure = parsed.value.object.get("error") orelse return error.TestUnexpectedResult;
        const code = failure.object.get("code") orelse return error.TestUnexpectedResult;
        try testing.expect(code == .integer and code.integer == -32602);
        return;
    }
    return error.TestUnexpectedResult;
}

// A heap snapshot is useful for leak diagnosis only if it retains application reference edges. Require user property names and the element edge in the CDP chunk, rather than class/name totals or root-only edges.
const InspectorEnabledTests = if (build_options.inspector) struct {
    test "cdp diagnostics: QuickJS heap snapshot exposes real reference edges without invoking accessors" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-heap-edges");
        defer session.deinit();
        const source =
            "globalThis.__heap_gets=0;" ++
            "globalThis.heap_parent={child:{marker:'heap-child'},list:[{marker:'heap-element'}]};" ++
            "Object.defineProperty(globalThis.heap_parent,'trap',{get(){globalThis.__heap_gets++;return 1;}});" ++
            "globalThis.__heap_proxy_gets=0;globalThis.heap_proxy=new Proxy({nested:{marker:'proxy-child'}},{get(t,k){globalThis.__heap_proxy_gets++;return t[k]}});" ++
            "Object.setPrototypeOf(globalThis.heap_parent,{protoMarker:'heap-prototype'});" ++
            "globalThis.heap_parent.self=globalThis.heap_parent;";
        const ran = engine.evalScript(session.id, source, "diagnostics-heap.js");
        if (ran.result) |v| std.heap.c_allocator.free(v);
        if (ran.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "HeapProfiler.takeHeapSnapshot", "", 1);
        try pumpResponse(&session, 1);
        const snapshot = try snapshotPayload(alloc, session.got.items);
        defer alloc.free(snapshot);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, snapshot, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const nodes = (root.get("nodes") orelse return error.TestUnexpectedResult).array.items;
        const edges = (root.get("edges") orelse return error.TestUnexpectedResult).array.items;
        const strings = (root.get("strings") orelse return error.TestUnexpectedResult).array.items;
        // Every CDP node occupies seven fields. Sum edge_count to prove the graph describes exactly the advertised edge vector, not a label-only summary.
        try testing.expect(nodes.len % 7 == 0);
        var edge_count: i64 = 0;
        var node: usize = 0;
        while (node < nodes.len) : (node += 7) {
            edge_count += try intAt(nodes, node + 4);
            const node_id = try intAt(nodes, node + 2);
            var other = node + 7;
            while (other < nodes.len) : (other += 7) {
                try testing.expect((try intAt(nodes, other + 2)) != node_id);
            }
        }
        try testing.expectEqual(@as(i64, @intCast(edges.len / 3)), edge_count);
        const child_name: i64 = @intCast(stringIndex(strings, "child") orelse return error.TestUnexpectedResult);
        const list_name: i64 = @intCast(stringIndex(strings, "list") orelse return error.TestUnexpectedResult);
        const self_name: i64 = @intCast(stringIndex(strings, "self") orelse return error.TestUnexpectedResult);
        try testing.expect(hasEdge(edges, 2, child_name, null));
        try testing.expect(hasEdge(edges, 2, list_name, null));
        try testing.expect(hasEdge(edges, 2, self_name, null));
        // Element edges are numeric-name CDP edges; an index 0 must be retained.
        try testing.expect(hasEdge(edges, 1, 0, null));
        // The cycle is represented by an edge whose destination is the source node's packed index. Derive source ranges from edge_count.
        var edge_start: usize = 0;
        node = 0;
        var saw_cycle = false;
        var saw_parent_child_group = false;
        while (node < nodes.len) : (node += 7) {
            const count: usize = @intCast(try intAt(nodes, node + 4));
            var has_child = false;
            var has_list = false;
            var has_self = false;
            var edge_i = edge_start;
            while (edge_i < edge_start + count) : (edge_i += 1) {
                const base = edge_i * 3;
                const edge_kind = try intAt(edges, base);
                const edge_name = try intAt(edges, base + 1);
                if (edge_kind == 2 and edge_name == child_name) has_child = true;
                if (edge_kind == 2 and edge_name == list_name) has_list = true;
                if (edge_kind == 2 and edge_name == self_name) {
                    has_self = true;
                    if (try intAt(edges, base + 2) == node) saw_cycle = true;
                }
            }
            if (has_child and has_list and has_self) saw_parent_child_group = true;
            edge_start += count;
        }
        try testing.expect(saw_cycle);
        try testing.expect(saw_parent_child_group);
        // This graph does not yet cover Map/Set/closures/weak references and all nodes are synthetic-rooted, so it must never claim a retained-size-grade complete heap even when no node budget was exhausted.
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"complete\":false") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"edgeCoverage\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"rootCoverage\":\"synthetic-root-all-nodes\"") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"retainedSizeSupported\":false") != null);
        try testing.expectEqual(@as(i64, 0), try helpers.evalInt(session.id, "globalThis.__heap_gets"));
        try testing.expectEqual(@as(i64, 0), try helpers.evalInt(session.id, "globalThis.__heap_proxy_gets"));
    }

    // CDP property names are data, not display labels: a fixed-size scratch buffer or C-string treatment aliases keys and loses embedded NUL suffixes. Use long names and require the actual edge names, not substrings.
    test "cdp diagnostics: QuickJS heap snapshot preserves long Unicode and NUL property names" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-heap-property-name-precision");
        defer session.deinit();
        const key_a = "中文属性名中文属性名中文属性名中文属性名中文属性名中文属性名中文属性名中文属性名A";
        const key_b = "中文属性名中文属性名中文属性名中文属性名中文属性名中文属性名中文属性名中文属性名B";
        const source =
            "globalThis.__heap_name_gets=0;" ++
            "globalThis.heap_name_precision={};" ++
            "globalThis.heap_name_precision['" ++ key_a ++ "']={value:'A'};" ++
            "globalThis.heap_name_precision['" ++ key_b ++ "']={value:'B'};" ++
            "globalThis.heap_name_precision['a\\u0000b']={value:'nul'};" ++
            "Object.defineProperty(globalThis.heap_name_precision,'getter',{get(){globalThis.__heap_name_gets++;return 1;}});";
        const ran = engine.evalScript(session.id, source, "heap-property-name-precision.js");
        if (ran.result) |v| std.heap.c_allocator.free(v);
        if (ran.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "HeapProfiler.takeHeapSnapshot", "", 1);
        try pumpResponse(&session, 1);
        const snapshot = try snapshotPayload(alloc, session.got.items);
        defer alloc.free(snapshot);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, snapshot, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const edges = (root.get("edges") orelse return error.TestUnexpectedResult).array.items;
        const strings = (root.get("strings") orelse return error.TestUnexpectedResult).array.items;
        const key_a_index: i64 = @intCast(stringIndex(strings, key_a) orelse return error.TestUnexpectedResult);
        const key_b_index: i64 = @intCast(stringIndex(strings, key_b) orelse return error.TestUnexpectedResult);
        const nul_key_index: i64 = @intCast(stringIndex(strings, "a\x00b") orelse return error.TestUnexpectedResult);
        try testing.expect(key_a_index != key_b_index);
        try testing.expect(hasEdge(edges, 2, key_a_index, null));
        try testing.expect(hasEdge(edges, 2, key_b_index, null));
        try testing.expect(hasEdge(edges, 2, nul_key_index, null));
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"truncated\":false") != null);
        try testing.expectEqual(@as(i64, 0), try helpers.evalInt(session.id, "globalThis.__heap_name_gets"));
    }

    test "cdp diagnostics: QuickJS heap snapshot labels node-budget truncation" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-heap-truncation");
        defer session.deinit();
        const ran = engine.evalScript(session.id, "globalThis.manyHeapObjects=[];for(var i=0;i<2300;i++)manyHeapObjects.push({i:i,pad:'heap-budget-marker-'+i});", "heap-truncation.js");
        if (ran.result) |v| std.heap.c_allocator.free(v);
        if (ran.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "HeapProfiler.takeHeapSnapshot", "", 1);
        try pumpResponse(&session, 1);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"truncated\":true") != null);
        try testing.expect((try unsignedField(session.got.items, "\"omittedNodes\":")) > 0);
    }

    test "cdp diagnostics: JSC reports heap snapshots as unsupported instead of a synthetic zero graph" {
        if (comptime !backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-jsc-heap-unsupported");
        defer session.deinit();
        try send(&session, "HeapProfiler.takeHeapSnapshot", "", 1);
        try pumpResponse(&session, 1);
        try expectUnsupportedResponse(session.got.items, 1);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"node_count\":3") == null);
    }

    test "cdp diagnostics: JSC reports heap usage as unsupported instead of zero bytes" {
        if (comptime !backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-jsc-heap-usage-unsupported");
        defer session.deinit();
        try send(&session, "Runtime.getHeapUsage", "", 1);
        try pumpResponse(&session, 1);
        try expectUnsupportedResponse(session.got.items, 1);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"usedSize\":0") == null);
    }

    // Profiles may use a bounded ring, but overwriting samples invisibly makes duration and hit counts misleading. The metadata is part of the public diagnostic contract and must explain every loss/truncation.
    test "cdp diagnostics: QuickJS profile reports retained, dropped, truncated, and monotonic timing" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-profile-accounting");
        defer session.deinit();
        try send(&session, "Profiler.enable", "", 1);
        try pumpResponse(&session, 1);
        try configureFastProfilerSampling(&session);
        try send(&session, "Profiler.start", "", 2);
        try pumpResponse(&session, 2);
        const ran = engine.evalScript(session.id, "function profileSpin(){var n=0;while(n<12000000)n++;} profileSpin();", "diagnostics-profile.js");
        if (ran.result) |v| std.heap.c_allocator.free(v);
        if (ran.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.stop", "", 3);
        try pumpResponse(&session, 3);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"jsbaySampling\":{") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"retainedSamples\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"droppedSamples\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"truncatedStacks\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"totalSamples\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"overwrittenSamples\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"startTimeUs\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"endTimeUs\":") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"clockResolutionUs\":1000") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"profileSpin\"") != null);
    }

    // Resizing the profile ring is an observable operation. A failed replacement must not claim start success or turn the following profile into stale data.
    test "cdp diagnostics: QuickJS profile resize OOM preserves the active session and retry is clean" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-profile-resize-oom");
        defer session.deinit();
        try configureFastProfilerSampling(&session);
        try send(&session, "Profiler.start", "{\"maxSamples\":64}", 1);
        try pumpResponse(&session, 1);
        const first = engine.evalScript(session.id, "function oomOldProfile(){var i=0;while(i<12000000)i++;}oomOldProfile();", "oom-old-profile.js");
        if (first.result) |v| std.heap.c_allocator.free(v);
        if (first.err) |v| std.heap.c_allocator.free(v);
        inspector.testFailAllocationOnce(session.id, .profiler_samples);
        try send(&session, "Profiler.start", "{\"maxSamples\":4096}", 2);
        try pumpResponse(&session, 2);
        try expectErrorResponse(session.got.items, 2);
        // Twenty thousand iterations cross several samples without replacing the active profiling window.
        const after_failed = engine.evalScript(session.id, "function oomStillActive(){var i=0;while(i<20000)i++;}oomStillActive();", "oom-still-active.js");
        if (after_failed.result) |v| std.heap.c_allocator.free(v);
        if (after_failed.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.stop", "", 3);
        try pumpResponse(&session, 3);
        const retained_profile = try responseLine(session.got.items, 3);
        try testing.expect(std.mem.indexOf(u8, retained_profile, "\"functionName\":\"oomOldProfile\"") != null);
        try testing.expect(std.mem.indexOf(u8, retained_profile, "\"functionName\":\"oomStillActive\"") != null);
        try testing.expectEqual(@as(u64, 64), try unsignedField(retained_profile, "\"retainedSamples\":"));
        try send(&session, "Profiler.start", "{\"maxSamples\":4096}", 4);
        try pumpResponse(&session, 4);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"id\":4,\"result\":{}") != null);
        const retried = engine.evalScript(session.id, "function oomRetryClean(){var i=0;while(i<12000000)i++;}oomRetryClean();", "oom-retry-clean.js");
        if (retried.result) |v| std.heap.c_allocator.free(v);
        if (retried.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.stop", "", 5);
        try pumpResponse(&session, 5);
        const retried_profile = try responseLine(session.got.items, 5);
        try testing.expect(std.mem.indexOf(u8, retried_profile, "\"functionName\":\"oomRetryClean\"") != null);
        try testing.expect(std.mem.indexOf(u8, retried_profile, "\"functionName\":\"oomOldProfile\"") == null);
        try testing.expect(std.mem.indexOf(u8, retried_profile, "\"functionName\":\"oomStillActive\"") == null);
    }

    test "cdp diagnostics: QuickJS profile string-buffer resize OOM preserves the active session and retry is clean" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-profile-string-resize-oom");
        defer session.deinit();
        try configureFastProfilerSampling(&session);
        try send(&session, "Profiler.start", "{\"maxSamples\":64}", 1);
        try pumpResponse(&session, 1);
        const first = engine.evalScript(session.id, "function oomStringsOld(){var i=0;while(i<12000000)i++;}oomStringsOld();", "oom-strings-old.js");
        if (first.result) |v| std.heap.c_allocator.free(v);
        if (first.err) |v| std.heap.c_allocator.free(v);
        inspector.testFailAllocationOnce(session.id, .profiler_strings);
        try send(&session, "Profiler.start", "{\"maxSamples\":4096}", 2);
        try pumpResponse(&session, 2);
        try expectErrorResponse(session.got.items, 2);
        const after_failed = engine.evalScript(session.id, "function oomStringsStillActive(){var i=0;while(i<20000)i++;}oomStringsStillActive();", "oom-strings-active.js");
        if (after_failed.result) |v| std.heap.c_allocator.free(v);
        if (after_failed.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.stop", "", 3);
        try pumpResponse(&session, 3);
        const retained_profile = try responseLine(session.got.items, 3);
        try testing.expect(std.mem.indexOf(u8, retained_profile, "\"functionName\":\"oomStringsOld\"") != null);
        try testing.expect(std.mem.indexOf(u8, retained_profile, "\"functionName\":\"oomStringsStillActive\"") != null);
        try send(&session, "Profiler.start", "{\"maxSamples\":4096}", 4);
        try pumpResponse(&session, 4);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"id\":4,\"result\":{}") != null);
        const retried = engine.evalScript(session.id, "function oomStringsRetry(){var i=0;while(i<12000000)i++;}oomStringsRetry();", "oom-strings-retry.js");
        if (retried.result) |v| std.heap.c_allocator.free(v);
        if (retried.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.stop", "", 5);
        try pumpResponse(&session, 5);
        const retried_profile = try responseLine(session.got.items, 5);
        try testing.expect(std.mem.indexOf(u8, retried_profile, "\"functionName\":\"oomStringsRetry\"") != null);
        try testing.expect(std.mem.indexOf(u8, retried_profile, "\"functionName\":\"oomStringsOld\"") == null);
        try testing.expect(std.mem.indexOf(u8, retried_profile, "\"functionName\":\"oomStringsStillActive\"") == null);
    }

    // A completion response without a snapshot chunk makes DevTools load an empty snapshot as success. The allocation hook targets only the chunk envelope so the failure cannot be mistaken for a graph traversal budget limit.
    test "cdp diagnostics: QuickJS heap chunk OOM returns an error without false completion and retry works" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-heap-chunk-oom");
        defer session.deinit();
        const ran = engine.evalScript(session.id, "globalThis.heapChunkOom={child:{value:42}};", "heap-chunk-oom.js");
        if (ran.result) |v| std.heap.c_allocator.free(v);
        if (ran.err) |v| std.heap.c_allocator.free(v);
        inspector.testFailAllocationOnce(session.id, .heap_snapshot_chunk);
        try send(&session, "HeapProfiler.takeHeapSnapshot", "", 1);
        try pumpResponse(&session, 1);
        try expectErrorResponse(session.got.items, 1);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "HeapProfiler.addHeapSnapshotChunk") == null);
        try send(&session, "HeapProfiler.takeHeapSnapshot", "", 2);
        try pumpResponse(&session, 2);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "HeapProfiler.addHeapSnapshotChunk") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"id\":2,\"result\":{\"jsbaySnapshot\":") != null);
    }

    test "cdp diagnostics: JSC reports CPU profiling as unsupported" {
        if (comptime !backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-jsc-profile-unsupported");
        defer session.deinit();
        try send(&session, "Profiler.start", "", 1);
        try pumpResponse(&session, 1);
        try expectUnsupportedResponse(session.got.items, 1);
    }

    test "cdp diagnostics: QuickJS profile maxSamples keeps an accountable trailing window" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-profile-window");
        defer session.deinit();
        try send(&session, "Profiler.enable", "", 1);
        try pumpResponse(&session, 1);
        try configureFastProfilerSampling(&session);
        try send(&session, "Profiler.start", "{\"maxSamples\":64}", 2);
        try pumpResponse(&session, 2);
        const ran = engine.evalScript(session.id, "function windowSpin(){var i=0;while(i<12000000)i++;}windowSpin();", "profile-window.js");
        if (ran.result) |v| std.heap.c_allocator.free(v);
        if (ran.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.stop", "", 3);
        try pumpResponse(&session, 3);
        const retained = try unsignedField(session.got.items, "\"retainedSamples\":");
        const total = try unsignedField(session.got.items, "\"totalSamples\":");
        const overwritten = try unsignedField(session.got.items, "\"overwrittenSamples\":");
        const retained_start = try unsignedField(session.got.items, "\"retainedStartTimeUs\":");
        const session_start = try unsignedField(session.got.items, "\"sessionStartTimeUs\":");
        try testing.expectEqual(@as(u64, 64), retained);
        try testing.expect(total > retained);
        try testing.expectEqual(total - retained, overwritten);
        try testing.expect(retained_start > session_start);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"startTime\":") != null);
    }

    test "cdp diagnostics: QuickJS rejects invalid profile maxSamples values" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-profile-window-invalid");
        defer session.deinit();
        try send(&session, "Profiler.start", "{\"maxSamples\":1.5}", 1);
        try pumpResponse(&session, 1);
        try expectInvalidParams(session.got.items, 1);
        try send(&session, "Profiler.start", "{\"maxSamples\":1}", 2);
        try pumpResponse(&session, 2);
        try expectInvalidParams(session.got.items, 2);
        try send(&session, "Profiler.start", "{\"maxSamples\":4097}", 3);
        try pumpResponse(&session, 3);
        try expectInvalidParams(session.got.items, 3);
    }

    test "cdp diagnostics: QuickJS second profile start resets the sampling window" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-profile-window-reset");
        defer session.deinit();
        try configureFastProfilerSampling(&session);
        try send(&session, "Profiler.start", "{\"maxSamples\":64}", 1);
        try pumpResponse(&session, 1);
        const first = engine.evalScript(session.id, "function firstWindow(){var i=0;while(i<12000000)i++;}firstWindow();", "first-window.js");
        if (first.result) |v| std.heap.c_allocator.free(v);
        if (first.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.start", "{\"maxSamples\":64}", 2);
        try pumpResponse(&session, 2);
        const second = engine.evalScript(session.id, "function secondWindow(){var i=0;while(i<400000)i++;}secondWindow();", "second-window.js");
        if (second.result) |v| std.heap.c_allocator.free(v);
        if (second.err) |v| std.heap.c_allocator.free(v);
        try send(&session, "Profiler.stop", "", 3);
        try pumpResponse(&session, 3);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"secondWindow\"") != null);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "\"functionName\":\"firstWindow\"") == null);
    }
};

comptime {
    _ = InspectorEnabledTests;
}

// This is intentionally a public C ABI assertion: feature stripping must not delete the symbol, and a production build must not leave a listener running.
const InspectorDisabledTests = if (!build_options.inspector) struct {
    test "c api diagnostics: inspector-disabled build retains ABI and refuses to listen" {
        const id = helpers.nextInstanceId();
        try testing.expect(c_api.jsbay_engine_create(id, null, null));
        defer c_api.jsbay_engine_destroy(id);
        var port: u16 = 99;
        try testing.expect(!c_api.jsbay_engine_inspector_start(id, 0, &port));
        try testing.expectEqual(@as(u16, 99), port);
    }
};

comptime {
    _ = InspectorDisabledTests;
}

const HeapSnapshotDisabledTests = if (build_options.inspector and !build_options.heap_snapshot) struct {
    test "cdp diagnostics: heap-snapshot-disabled build keeps inspector but rejects snapshots" {
        const alloc = testing.allocator;
        var session = try openSession(alloc, "diagnostics-heap-feature-off");
        defer session.deinit();
        try send(&session, "HeapProfiler.takeHeapSnapshot", "", 1);
        try pumpResponse(&session, 1);
        try expectUnsupportedResponse(session.got.items, 1);
        try testing.expect(std.mem.indexOf(u8, session.got.items, "HeapProfiler.addHeapSnapshotChunk") == null);
    }
};

comptime {
    _ = HeapSnapshotDisabledTests;
}
