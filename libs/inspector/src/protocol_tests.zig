//! Tests for the pure-logic CDP protocol dispatcher. No engine or network — we drive `handleMessage` with synthetic JSON requests and assert on the replies/events captured by a test Sink.

const std = @import("std");
const testing = std.testing;
const proto = @import("inspector").protocol;

// ---------------------------------------------------------------------------
// Test harness: capture Sink + programmable Services
// ---------------------------------------------------------------------------

const Capture = struct {
    alloc: std.mem.Allocator,
    replies: std.ArrayList([]u8),
    events: std.ArrayList([]u8),

    fn init(alloc: std.mem.Allocator) Capture {
        return .{
            .alloc = alloc,
            .replies = .empty,
            .events = .empty,
        };
    }

    fn deinit(self: *Capture) void {
        for (self.replies.items) |s| self.alloc.free(s);
        for (self.events.items) |s| self.alloc.free(s);
        self.replies.deinit(self.alloc);
        self.events.deinit(self.alloc);
    }

    fn sink(self: *Capture) proto.Sink {
        return .{
            .ctx = self,
            .send_reply = onReply,
            .send_event = onEvent,
        };
    }

    fn onReply(ctx: ?*anyopaque, json: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        const copy = self.alloc.dupe(u8, json) catch return;
        self.replies.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }

    fn onEvent(ctx: ?*anyopaque, json: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx.?));
        const copy = self.alloc.dupe(u8, json) catch return;
        self.events.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }
};

const MockEval = struct {
    outcome: proto.EvalOutcome,

    fn services(self: *MockEval, target_id: []const u8) proto.Services {
        return .{
            .ctx = self,
            .eval = evalFn,
            .target_id = target_id,
        };
    }

    fn evalFn(ctx: ?*anyopaque, expression: []const u8) proto.EvalOutcome {
        _ = expression;
        const self: *MockEval = @ptrCast(@alignCast(ctx.?));
        return self.outcome;
    }
};

fn defaultServices(target_id: []const u8) proto.Services {
    return .{
        .ctx = null,
        .eval = stubEval,
        .target_id = target_id,
    };
}

fn stubEval(ctx: ?*anyopaque, expression: []const u8) proto.EvalOutcome {
    _ = ctx;
    _ = expression;
    return .{ .ok = true, .text = "undefined" };
}

// A tiny helper: parse a captured JSON blob into a tree for inspection.
fn parseTree(alloc: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
}

fn objectField(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "unknown method yields method-not-found error with request id" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    const req = "{\"id\":42,\"method\":\"NoSuchDomain.whatever\"}";
    proto.handleMessage(alloc, defaultServices("tgt"), cap.sink(), req);

    try testing.expectEqual(@as(usize, 1), cap.replies.items.len);
    try testing.expectEqual(@as(usize, 0), cap.events.items.len);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 42), objectField(parsed.value, "id").?.integer);
    const err_obj = objectField(parsed.value, "error").?;
    try testing.expectEqual(@as(i64, -32601), objectField(err_obj, "code").?.integer);
    try testing.expectEqualStrings("Method not found", objectField(err_obj, "message").?.string);
}

test "missing id is silently dropped" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    const req = "{\"method\":\"Runtime.enable\"}";
    proto.handleMessage(alloc, defaultServices("tgt"), cap.sink(), req);

    try testing.expectEqual(@as(usize, 0), cap.replies.items.len);
    try testing.expectEqual(@as(usize, 0), cap.events.items.len);
}

test "Runtime.enable emits reply then executionContextCreated event" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    const req = "{\"id\":1,\"method\":\"Runtime.enable\"}";
    proto.handleMessage(alloc, defaultServices("my-target-id"), cap.sink(), req);

    try testing.expectEqual(@as(usize, 1), cap.replies.items.len);
    try testing.expectEqual(@as(usize, 1), cap.events.items.len);

    // Reply body is `{"id":1,"result":{}}`.
    var reply = try parseTree(alloc, cap.replies.items[0]);
    defer reply.deinit();
    try testing.expectEqual(@as(i64, 1), objectField(reply.value, "id").?.integer);
    const result = objectField(reply.value, "result").?;
    try testing.expect(result == .object);
    try testing.expectEqual(@as(usize, 0), result.object.count());

    var evt = try parseTree(alloc, cap.events.items[0]);
    defer evt.deinit();
    try testing.expectEqualStrings(
        "Runtime.executionContextCreated",
        objectField(evt.value, "method").?.string,
    );
    const params = objectField(evt.value, "params").?;
    const ctx = objectField(params, "context").?;
    try testing.expectEqual(@as(i64, 1), objectField(ctx, "id").?.integer);
    try testing.expectEqualStrings(
        "my-target-id",
        objectField(ctx, "uniqueId").?.string,
    );
}

test "Runtime.evaluate success: integer" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    var mock = MockEval{ .outcome = .{ .ok = true, .text = "42" } };
    const req = "{\"id\":10,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"21+21\"}}";
    proto.handleMessage(alloc, mock.services("tgt"), cap.sink(), req);

    try testing.expectEqual(@as(usize, 1), cap.replies.items.len);
    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();

    const inner = objectField(objectField(parsed.value, "result").?, "result").?;
    try testing.expectEqualStrings("number", objectField(inner, "type").?.string);
    // value may arrive as integer or float depending on how std.json parses.
    const val = objectField(inner, "value").?;
    const asI = switch (val) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => unreachable,
    };
    try testing.expectEqual(@as(i64, 42), asI);
}

test "Runtime.evaluate success: string" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    var mock = MockEval{ .outcome = .{ .ok = true, .text = "\"hi\"" } };
    const req = "{\"id\":11,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"'hi'\"}}";
    proto.handleMessage(alloc, mock.services("tgt"), cap.sink(), req);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();
    const inner = objectField(objectField(parsed.value, "result").?, "result").?;
    try testing.expectEqualStrings("string", objectField(inner, "type").?.string);
    try testing.expectEqualStrings("hi", objectField(inner, "value").?.string);
}

test "Runtime.evaluate success: boolean" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    var mock = MockEval{ .outcome = .{ .ok = true, .text = "true" } };
    const req = "{\"id\":12,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"true\"}}";
    proto.handleMessage(alloc, mock.services("tgt"), cap.sink(), req);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();
    const inner = objectField(objectField(parsed.value, "result").?, "result").?;
    try testing.expectEqualStrings("boolean", objectField(inner, "type").?.string);
    try testing.expectEqual(true, objectField(inner, "value").?.bool);
}

test "Runtime.evaluate success: undefined" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    var mock = MockEval{ .outcome = .{ .ok = true, .text = "undefined" } };
    const req = "{\"id\":13,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"void 0\"}}";
    proto.handleMessage(alloc, mock.services("tgt"), cap.sink(), req);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();
    const inner = objectField(objectField(parsed.value, "result").?, "result").?;
    try testing.expectEqualStrings("undefined", objectField(inner, "type").?.string);
    // No `value` key for undefined.
    try testing.expect(objectField(inner, "value") == null);
}

test "Runtime.evaluate success: object fallback" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    var mock = MockEval{ .outcome = .{ .ok = true, .text = "{x:1}" } };
    const req = "{\"id\":14,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"({x:1})\"}}";
    proto.handleMessage(alloc, mock.services("tgt"), cap.sink(), req);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();
    const inner = objectField(objectField(parsed.value, "result").?, "result").?;
    try testing.expectEqualStrings("object", objectField(inner, "type").?.string);
    try testing.expectEqualStrings("{x:1}", objectField(inner, "description").?.string);
}

test "Runtime.evaluate exception: error_name + message" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    var mock = MockEval{ .outcome = .{
        .ok = false,
        .text = "boom",
        .error_name = "TypeError",
    } };
    const req = "{\"id\":15,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"throw new TypeError('boom')\"}}";
    proto.handleMessage(alloc, mock.services("tgt"), cap.sink(), req);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();

    const result = objectField(parsed.value, "result").?;
    const inner = objectField(result, "result").?;
    try testing.expectEqualStrings("object", objectField(inner, "type").?.string);
    try testing.expectEqualStrings("error", objectField(inner, "subtype").?.string);
    try testing.expectEqualStrings("TypeError", objectField(inner, "className").?.string);
    try testing.expectEqualStrings("boom", objectField(inner, "description").?.string);

    const details = objectField(result, "exceptionDetails").?;
    try testing.expect(objectField(details, "exceptionId") != null);
    try testing.expectEqualStrings("Uncaught", objectField(details, "text").?.string);
    const exc = objectField(details, "exception").?;
    try testing.expectEqualStrings("TypeError", objectField(exc, "className").?.string);
    try testing.expectEqualStrings("boom", objectField(exc, "description").?.string);
}

test "Runtime.getIsolateId returns target_id" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    const req = "{\"id\":20,\"method\":\"Runtime.getIsolateId\"}";
    proto.handleMessage(alloc, defaultServices("iso-xyz"), cap.sink(), req);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();
    const result = objectField(parsed.value, "result").?;
    try testing.expectEqualStrings("iso-xyz", objectField(result, "id").?.string);
}

test "Debugger.enable returns debuggerId" {
    const alloc = testing.allocator;
    var cap = Capture.init(alloc);
    defer cap.deinit();

    const req = "{\"id\":30,\"method\":\"Debugger.enable\"}";
    proto.handleMessage(alloc, defaultServices("dbg-abc"), cap.sink(), req);

    var parsed = try parseTree(alloc, cap.replies.items[0]);
    defer parsed.deinit();
    const result = objectField(parsed.value, "result").?;
    try testing.expectEqualStrings("dbg-abc", objectField(result, "debuggerId").?.string);
}

test "buildConsoleApiCalled produces parseable event with expected fields" {
    const alloc = testing.allocator;
    const json = try proto.buildConsoleApiCalled(alloc, 1, "warning", "hello world", 1234.5);
    defer alloc.free(json);

    var parsed = try parseTree(alloc, json);
    defer parsed.deinit();

    try testing.expectEqualStrings(
        "Runtime.consoleAPICalled",
        objectField(parsed.value, "method").?.string,
    );
    const params = objectField(parsed.value, "params").?;
    try testing.expectEqualStrings("warning", objectField(params, "type").?.string);

    const args = objectField(params, "args").?;
    try testing.expect(args == .array);
    try testing.expectEqual(@as(usize, 1), args.array.items.len);
    const arg0 = args.array.items[0];
    try testing.expectEqualStrings("string", objectField(arg0, "type").?.string);
    try testing.expectEqualStrings("hello world", objectField(arg0, "value").?.string);

    const ctxid = objectField(params, "executionContextId").?;
    const asI = switch (ctxid) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => unreachable,
    };
    try testing.expectEqual(@as(i64, 1), asI);
}

test "buildExecutionContextCreated parses back with uniqueId=target_id" {
    const alloc = testing.allocator;
    const json = try proto.buildExecutionContextCreated(alloc, 7, "target-42");
    defer alloc.free(json);

    var parsed = try parseTree(alloc, json);
    defer parsed.deinit();

    try testing.expectEqualStrings(
        "Runtime.executionContextCreated",
        objectField(parsed.value, "method").?.string,
    );
    const params = objectField(parsed.value, "params").?;
    const ctx = objectField(params, "context").?;
    try testing.expectEqual(@as(i64, 7), objectField(ctx, "id").?.integer);
    try testing.expectEqualStrings("target-42", objectField(ctx, "uniqueId").?.string);
}
