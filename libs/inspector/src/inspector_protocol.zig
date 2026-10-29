// Pure-logic Chrome DevTools Protocol (CDP) request dispatcher.
//
// This module is intentionally free of networking, threading and engine dependencies. Given a single CDP request JSON and a `Services` callback bag, it produces a reply JSON (and sometimes one or more event JSONs) via a `Sink` callback bag.
//
// The real inspector (`inspector.zig`) wires this module up to a WebSocket transport and the JS engine. Tests can drive it directly with synthetic requests.
//
// ## Threading
//
// `handleMessage` is synchronous. The caller guarantees that any call into `services.eval` is safe to make from the current thread (in production the real inspector marshals requests to the JS thread before invoking this dispatcher, or invokes `eval` via an internal postTask; either way is opaque here).
//
// ## Allocation contract
//
// - All JSON strings passed to `sink.send_reply` / `sink.send_event` are backed by `allocator` and freed before `handleMessage` returns. Sinks therefore must copy if they want to retain.
// - `buildConsoleApiCalled` / `buildExecutionContextCreated` return an owned slice; callers are responsible for freeing with the same allocator they passed in.

const std = @import("std");

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub const EvalOutcome = struct {
    ok: bool,
    /// Borrowed, valid for the duration of the handleMessage call. The dispatcher copies into JSON output as needed.
    text: []const u8,
    /// When ok=false, optionally the JS error class ("TypeError", "Error", etc.).
    error_name: []const u8 = "",
};

pub const Services = struct {
    ctx: ?*anyopaque,
    /// Evaluate a JS expression synchronously. Caller of handleMessage guarantees this is invoked on the JS thread. Inspector sets this up via postTask.
    eval: *const fn (ctx: ?*anyopaque, expression: []const u8) EvalOutcome,
    /// Stable target id — used as contextId.uniqueId and debuggerId.
    target_id: []const u8,
};

pub const Sink = struct {
    ctx: ?*anyopaque,
    /// Send JSON as a response to the current request. Called at most once per handleMessage. The JSON is borrowed — sink must copy if retaining past the call.
    send_reply: *const fn (ctx: ?*anyopaque, json: []const u8) void,
    /// Send a JSON event to the current session. May be called zero or more times per handleMessage (Runtime.enable emits executionContextCreated).
    send_event: *const fn (ctx: ?*anyopaque, json: []const u8) void,
};

// ---------------------------------------------------------------------------
// Monotonic exception id counter — global to the module.
// ---------------------------------------------------------------------------

var exception_id_counter = std.atomic.Value(u64).init(0);

fn nextExceptionId() u64 {
    return exception_id_counter.fetchAdd(1, .monotonic) + 1;
}

// ---------------------------------------------------------------------------
// Top-level dispatch
// ---------------------------------------------------------------------------

// Parse `text` as a CDP request, dispatch, and drive `sink` with reply + events. Never returns an error — protocol-level problems (bad JSON, unknown method, etc.) become JSON error replies or silent drops.
pub fn handleMessage(
    allocator: std.mem.Allocator,
    services: Services,
    sink: Sink,
    text: []const u8,
) void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch {
        // Unparseable. CDP is JSON-RPC over WS and the spec allows server-initiated frames, so silently dropping a bad request is acceptable.
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return;
    const root = parsed.value.object;

    const id_opt: ?i64 = blk: {
        const id_val = root.get("id") orelse break :blk null;
        break :blk switch (id_val) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    };

    const method_val = root.get("method") orelse {
        // No method → nothing to dispatch. Silently drop.
        return;
    };
    if (method_val != .string) return;
    const method = method_val.string;

    // If id is missing, CDP says we can silently drop — we do that for everything including unknown methods.
    const id = id_opt orelse return;

    dispatch(allocator, services, sink, id, method, parsed.value) catch |err| {
        // We only reach here when JSON building OOMs. Best effort: emit a minimal error reply that's pre-shaped.
        std.log.scoped(.inspector_protocol).warn(
            "handleMessage: failed to build reply for {s}: {s}",
            .{ method, @errorName(err) },
        );
    };
}

fn dispatch(
    allocator: std.mem.Allocator,
    services: Services,
    sink: Sink,
    id: i64,
    method: []const u8,
    root: std.json.Value,
) !void {
    // Methods that reply with `{}` are the bulk of the surface.
    if (std.mem.eql(u8, method, "Runtime.enable")) {
        try sendEmptyResult(allocator, sink, id);
        const ev = try buildExecutionContextCreated(allocator, 1, services.target_id);
        defer allocator.free(ev);
        sink.send_event(sink.ctx, ev);
        return;
    }
    if (std.mem.eql(u8, method, "Runtime.evaluate")) {
        try handleEvaluate(allocator, services, sink, id, root);
        return;
    }
    if (std.mem.eql(u8, method, "Runtime.getIsolateId")) {
        try sendIsolateId(allocator, sink, id, services.target_id);
        return;
    }
    if (std.mem.eql(u8, method, "Runtime.getHeapUsage")) {
        try sendHeapUsage(allocator, sink, id);
        return;
    }
    if (std.mem.eql(u8, method, "Runtime.compileScript")) {
        try sendCompileScript(allocator, sink, id);
        return;
    }
    if (std.mem.eql(u8, method, "Runtime.awaitPromise")) {
        try sendAwaitPromise(allocator, sink, id);
        return;
    }
    if (std.mem.eql(u8, method, "Debugger.enable")) {
        try sendDebuggerEnabled(allocator, sink, id, services.target_id);
        return;
    }

    if (isNoOpMethod(method)) {
        try sendEmptyResult(allocator, sink, id);
        return;
    }

    try sendMethodNotFound(allocator, sink, id);
}

fn isNoOpMethod(method: []const u8) bool {
    const stubs = [_][]const u8{
        "Runtime.disable",
        "Runtime.releaseObject",
        "Runtime.releaseObjectGroup",
        "Runtime.discardConsoleEntries",
        "Runtime.runIfWaitingForDebugger",
        "Debugger.disable",
        "Debugger.setBreakpointsActive",
        "Debugger.setSkipAllPauses",
        "Debugger.setPauseOnExceptions",
        "Debugger.setAsyncCallStackDepth",
        "Debugger.setBlackboxPatterns",
        "Debugger.setBlackboxExecutionContexts",
        "Log.enable",
        "Log.disable",
        "Log.clear",
        "Log.startViolationsReport",
        "Profiler.enable",
        "Profiler.disable",
        "Page.enable",
        "DOM.enable",
        "CSS.enable",
        "Target.setDiscoverTargets",
    };
    for (stubs) |s| {
        if (std.mem.eql(u8, method, s)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Reply builders — we hand-write the JSON via std.fmt / writeJsonString. std.json.stringify on anonymous structs would cover most cases, but the Runtime.evaluate response has a shape that varies by result type (fields present/absent, value typed rather than quoted) which is awkward to express with a single anon-struct literal. Hand-writing is ~the same length and avoids duplicating code paths for each variant.
// ---------------------------------------------------------------------------

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var buf: [8]u8 = undefined;
                const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                try writer.writeAll(esc);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn sendEmptyResult(allocator: std.mem.Allocator, sink: Sink, request_id: i64) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print("{{\"id\":{d},\"result\":{{}}}}", .{request_id});
    sink.send_reply(sink.ctx, aw.written());
}

fn sendIsolateId(
    allocator: std.mem.Allocator,
    sink: Sink,
    request_id: i64,
    target_id: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"id\":{d},\"result\":{{\"id\":", .{request_id});
    try writeJsonString(w, target_id);
    try w.writeAll("}}");
    sink.send_reply(sink.ctx, aw.written());
}

fn sendHeapUsage(allocator: std.mem.Allocator, sink: Sink, request_id: i64) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"id\":{d},\"result\":{{\"usedSize\":0,\"totalSize\":0}}}}",
        .{request_id},
    );
    sink.send_reply(sink.ctx, aw.written());
}

fn sendCompileScript(allocator: std.mem.Allocator, sink: Sink, request_id: i64) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"id\":{d},\"result\":{{\"scriptId\":\"1\"}}}}",
        .{request_id},
    );
    sink.send_reply(sink.ctx, aw.written());
}

fn sendAwaitPromise(allocator: std.mem.Allocator, sink: Sink, request_id: i64) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"id\":{d},\"result\":{{\"result\":{{\"type\":\"undefined\"}}}}}}",
        .{request_id},
    );
    sink.send_reply(sink.ctx, aw.written());
}

fn sendDebuggerEnabled(
    allocator: std.mem.Allocator,
    sink: Sink,
    request_id: i64,
    target_id: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\"id\":{d},\"result\":{{\"debuggerId\":", .{request_id});
    try writeJsonString(w, target_id);
    try w.writeAll("}}");
    sink.send_reply(sink.ctx, aw.written());
}

fn sendMethodNotFound(allocator: std.mem.Allocator, sink: Sink, request_id: i64) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}",
        .{request_id},
    );
    sink.send_reply(sink.ctx, aw.written());
}

// ---------------------------------------------------------------------------
// Runtime.evaluate
// ---------------------------------------------------------------------------

const EvalKind = enum { undef, null_, boolean, integer, float, string, object };

fn classifyEvalResult(text: []const u8) EvalKind {
    if (text.len == 0) return .string;
    if (std.mem.eql(u8, text, "undefined")) return .undef;
    if (std.mem.eql(u8, text, "null")) return .null_;
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return .boolean;

    // A JSON-quoted string: leading & trailing double-quote.
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return .string;

    if (isIntegerLiteral(text)) return .integer;
    if (isFloatLiteral(text)) return .float;
    return .object;
}

fn isIntegerLiteral(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[0] == '-') {
        if (text.len == 1) return false;
        i = 1;
    }
    while (i < text.len) : (i += 1) {
        if (text[i] < '0' or text[i] > '9') return false;
    }
    return true;
}

fn isFloatLiteral(text: []const u8) bool {
    // ^-?\d+\.\d+$
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[0] == '-') {
        if (text.len == 1) return false;
        i = 1;
    }
    // integer part: at least one digit
    var had_int_digit = false;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        had_int_digit = true;
    }
    if (!had_int_digit) return false;
    if (i >= text.len or text[i] != '.') return false;
    i += 1;
    // fractional part: at least one digit
    var had_frac_digit = false;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        had_frac_digit = true;
    }
    if (!had_frac_digit) return false;
    return i == text.len;
}

fn handleEvaluate(
    allocator: std.mem.Allocator,
    services: Services,
    sink: Sink,
    request_id: i64,
    root: std.json.Value,
) !void {
    const expression: []const u8 = blk: {
        if (root != .object) break :blk "";
        const params_val = root.object.get("params") orelse break :blk "";
        if (params_val != .object) break :blk "";
        const expr_val = params_val.object.get("expression") orelse break :blk "";
        if (expr_val != .string) break :blk "";
        break :blk expr_val.string;
    };

    const outcome = services.eval(services.ctx, expression);

    if (outcome.ok) {
        try sendEvalSuccess(allocator, sink, request_id, outcome.text);
    } else {
        try sendEvalException(allocator, sink, request_id, outcome.text, outcome.error_name);
    }
}

fn sendEvalSuccess(
    allocator: std.mem.Allocator,
    sink: Sink,
    request_id: i64,
    text: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"id\":{d},\"result\":{{\"result\":{{\"type\":", .{request_id});

    const kind = classifyEvalResult(text);
    switch (kind) {
        .undef => {
            try w.writeAll("\"undefined\"");
        },
        .null_ => {
            try w.writeAll("\"object\",\"subtype\":\"null\",\"value\":null");
        },
        .boolean => {
            try w.writeAll("\"boolean\",\"value\":");
            try w.writeAll(text);
        },
        .integer, .float => {
            try w.writeAll("\"number\",\"value\":");
            try w.writeAll(text);
            try w.writeAll(",\"description\":");
            try writeJsonString(w, text);
        },
        .string => {
            // `text` is a JSON-quoted string (e.g. `"hi"`); the inner value is the unquoted content. We re-emit the same literal as the CDP `value` field — that round-trips the quoting for us.
            try w.writeAll("\"string\",\"value\":");
            try w.writeAll(text);
        },
        .object => {
            try w.writeAll("\"object\",\"className\":\"Object\",\"description\":");
            try writeJsonString(w, text);
        },
    }

    try w.writeAll("}}}");
    sink.send_reply(sink.ctx, aw.written());
}

fn sendEvalException(
    allocator: std.mem.Allocator,
    sink: Sink,
    request_id: i64,
    message: []const u8,
    error_name: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const class: []const u8 = if (error_name.len == 0) "Error" else error_name;
    const eid = nextExceptionId();

    try w.print("{{\"id\":{d},\"result\":{{\"result\":{{\"type\":\"object\",\"subtype\":\"error\",\"className\":", .{request_id});
    try writeJsonString(w, class);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, message);
    try w.print("}},\"exceptionDetails\":{{\"exceptionId\":{d},\"text\":\"Uncaught\",\"lineNumber\":0,\"columnNumber\":0,\"exception\":{{\"type\":\"object\",\"subtype\":\"error\",\"className\":", .{eid});
    try writeJsonString(w, class);
    try w.writeAll(",\"description\":");
    try writeJsonString(w, message);
    try w.writeAll("}}}}");

    sink.send_reply(sink.ctx, aw.written());
}

// ---------------------------------------------------------------------------
// Event builders (exported)
// ---------------------------------------------------------------------------

// Build a Runtime.consoleAPICalled event JSON for a console call. Caller frees with allocator.
pub fn buildConsoleApiCalled(
    allocator: std.mem.Allocator,
    execution_context_id: i32,
    level_tag: []const u8,
    message: []const u8,
    timestamp_ms: f64,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"method\":\"Runtime.consoleAPICalled\",\"params\":{\"type\":");
    try writeJsonString(w, level_tag);
    try w.writeAll(",\"args\":[{\"type\":\"string\",\"value\":");
    try writeJsonString(w, message);
    try w.writeAll("}],\"executionContextId\":");
    try w.print("{d}", .{execution_context_id});
    try w.writeAll(",\"timestamp\":");
    // f64 with JSON-safe decimal formatting.
    try w.print("{d}", .{timestamp_ms});
    try w.writeAll(",\"stackTrace\":{\"callFrames\":[]}}}");

    var list = aw.toArrayList();
    return list.toOwnedSlice(allocator);
}

// Build a Runtime.executionContextCreated event JSON. Caller frees with allocator.
pub fn buildExecutionContextCreated(
    allocator: std.mem.Allocator,
    execution_context_id: i32,
    target_id: []const u8,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"method\":\"Runtime.executionContextCreated\",\"params\":{\"context\":{\"id\":");
    try w.print("{d}", .{execution_context_id});
    try w.writeAll(",\"origin\":\"\",\"name\":\"js-bay\",\"uniqueId\":");
    try writeJsonString(w, target_id);
    try w.writeAll("}}}");

    var list = aw.toArrayList();
    return list.toOwnedSlice(allocator);
}
