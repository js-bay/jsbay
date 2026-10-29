//! Tests for console.log / info / warn / error / debug.
//!
//! console.* methods route to the instance's `log_handler` with the correct LogLevel and a pre-formatted message string. These tests install a capturing handler and assert on the messages/levels it receives.

const std = @import("std");
const sync = @import("zev");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const types = @import("../types.zig");
const helpers = @import("test_helpers.zig");

var reentrant_context_seen = false;
var reentrant_instance_id: i32 = 0;

fn reentrantLog(
    instance_id: i32,
    _: types.LogLevel,
    _: [*:0]const u8,
    _: ?*anyopaque,
) callconv(.c) void {
    reentrant_instance_id = instance_id;
    reentrant_context_seen = engine.getContext(instance_id) != null;
}

var self_destroyed_instance_id: i32 = 0;

fn destroyFromLog(
    instance_id: i32,
    _: types.LogLevel,
    _: [*:0]const u8,
    _: ?*anyopaque,
) callconv(.c) void {
    self_destroyed_instance_id = instance_id;
    engine.destroy(instance_id);
}

// ---------------------------------------------------------------------------
// Log capture.
//
// The captured entries are stored in a process-global because the C ABI log handler can't close over Zig locals. Each test that uses the handler must call `g_log_capture = LogCapture.init()` and `defer g_log_capture.deinit()`.
// ---------------------------------------------------------------------------

const LogCapture = struct {
    messages: std.ArrayList([]u8),
    levels: std.ArrayList(types.LogLevel),
    mutex: sync.Mutex = .{},

    fn init() LogCapture {
        return .{
            .messages = .empty,
            .levels = .empty,
        };
    }

    fn deinit(self: *LogCapture) void {
        for (self.messages.items) |m| std.heap.c_allocator.free(m);
        self.messages.deinit(std.heap.c_allocator);
        self.levels.deinit(std.heap.c_allocator);
        self.mutex.deinit();
    }

    fn count(self: *LogCapture) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len;
    }
};

var g_log_capture: LogCapture = undefined;

fn captureLog(
    instance_id: i32,
    level: types.LogLevel,
    msg: [*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = instance_id;
    _ = user_data;
    g_log_capture.mutex.lock();
    defer g_log_capture.mutex.unlock();
    const s = std.mem.span(msg);
    const owned = std.heap.c_allocator.dupe(u8, s) catch return;
    g_log_capture.messages.append(std.heap.c_allocator, owned) catch {
        std.heap.c_allocator.free(owned);
        return;
    };
    g_log_capture.levels.append(std.heap.c_allocator, level) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "console: log routes to handler at debug level" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log('hello')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expectEqual(types.LogLevel.debug, g_log_capture.levels.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "hello") != null);
}

test "console: handler may re-enter the instance registry" {
    reentrant_context_seen = false;
    reentrant_instance_id = 0;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &reentrantLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log('re-enter')");
    try testing.expectEqual(id, reentrant_instance_id);
    try testing.expect(reentrant_context_seen);
}

test "console: handler may destroy its own instance" {
    self_destroyed_instance_id = 0;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &destroyFromLog }));

    try helpers.evalOk(id, "console.log('destroy')");
    try testing.expectEqual(id, self_destroyed_instance_id);
    try testing.expect(engine.getContext(id) == null);
}

test "console: duplicate time labels do not replace the live timer" {
    if (!comptime backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.time('duplicate'); console.time('duplicate'); console.timeEnd('duplicate');");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "duplicate:") != null);
}

test "console: time state is removed before an instance id is reused" {
    if (!comptime backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    try helpers.evalOk(id, "console.time('stale')");
    engine.destroy(id);

    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);
    try helpers.evalOk(id, "console.timeEnd('stale')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "does not exist") != null);
}

test "console: timer count is bounded per instance" {
    if (!comptime backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "for (var i = 0; i < 257; i++) console.time('limit-' + i); console.timeEnd('limit-256')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "does not exist") != null);
}

test "console: info routes at info level" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.info('informational')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expectEqual(types.LogLevel.info, g_log_capture.levels.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "informational") != null);
}

test "console: warn routes at warn level" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.warn('careful')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expectEqual(types.LogLevel.warn, g_log_capture.levels.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "careful") != null);
}

test "console: error routes at err level" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.error('bad')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expectEqual(types.LogLevel.err, g_log_capture.levels.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "bad") != null);
}

test "console: debug routes at debug level" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.debug('trace')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expectEqual(types.LogLevel.debug, g_log_capture.levels.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "trace") != null);
}

test "console: multiple args are space-joined" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log('a', 'b', 42)");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expectEqualStrings("a b 42", g_log_capture.messages.items[0]);
}

test "console: long and unicode arguments are not truncated" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log('a'.repeat(4096), 'Ω')");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    const message = g_log_capture.messages.items[0];
    try testing.expectEqual(@as(usize, 4096 + " Ω".len), message.len);
    try testing.expect(std.mem.endsWith(u8, message, " Ω"));
}

test "console: object argument is JSON-stringified" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log({x:1})");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "\"x\":1") != null);
}

test "console: array argument is JSON-stringified" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log([1,2,3])");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "[1,2,3]") != null);
}

test "console: null argument renders as 'null'" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log(null)");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "null") != null);
}

test "console: undefined argument renders as 'undefined'" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log(undefined)");
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "undefined") != null);
}

test "console: log without handler does not crash" {
    // No log_handler configured — jsConsoleLog should silently drop the message.
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    try helpers.evalOk(id, "console.log('dropped'); console.info('also dropped'); console.error('ditto');");
    // Reaching here without aborting is success.
    try testing.expect(true);
}

test "console: multiple log calls accumulate in handler" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id,
        \\console.log('one');
        \\console.info('two');
        \\console.warn('three');
        \\console.error('four');
        \\console.debug('five');
    );

    try testing.expectEqual(@as(usize, 5), g_log_capture.count());
    try testing.expectEqual(types.LogLevel.debug, g_log_capture.levels.items[0]);
    try testing.expectEqual(types.LogLevel.info, g_log_capture.levels.items[1]);
    try testing.expectEqual(types.LogLevel.warn, g_log_capture.levels.items[2]);
    try testing.expectEqual(types.LogLevel.err, g_log_capture.levels.items[3]);
    try testing.expectEqual(types.LogLevel.debug, g_log_capture.levels.items[4]);

    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[0], "one") != null);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[1], "two") != null);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[2], "three") != null);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[3], "four") != null);
    try testing.expect(std.mem.indexOf(u8, g_log_capture.messages.items[4], "five") != null);
}

// ---------------------------------------------------------------------------
// Formatting values that cannot be serialized plainly must not poison the engine. The output text is deliberately not asserted.
//
// ---------------------------------------------------------------------------

const hostile_console_args = [_][]const u8{
    "{ a: 1n }",
    "10n",
    "(function () { var o = { name: 'loop' }; o.self = o; return o; })()",
    "[(function () { var a = []; a.push(a); return a; })()]",
    "function namedFn() { return 1; }",
    "(() => 1)",
    "new Error('formatted error')",
    "(function () { var e = new TypeError('with cause'); e.cause = e; return e; })()",
    "{ toJSON: function () { throw new Error('toJSON failed'); } }",
    "{ get boom() { throw new Error('getter failed'); } }",
    "Symbol('tag')",
    "{ [Symbol('key')]: 1, nested: { deep: 2n } }",
    "new Proxy({}, { ownKeys: function () { throw new Error('ownKeys failed'); } })",
};

fn expectConsoleLeavesEngineClean(comptime method: []const u8) !void {
    for (hostile_console_args) |arg| {
        g_log_capture = LogCapture.init();
        defer g_log_capture.deinit();

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
        defer engine.destroy(id);

        var buf: [512]u8 = undefined;
        // The call itself may legitimately throw into the script for a hostile value; guard it so the eval outcome only reflects exceptions left behind by the host.
        const script = try std.fmt.bufPrint(&buf, "try {{ console." ++ method ++ "({s}); }} catch (e) {{}} 0", .{arg});
        const res = engine.evalScript(id, script, "<console-hostile>");
        defer helpers.freeEvalResult(res);
        if (res.err != null) {
            std.debug.print("console." ++ method ++ " left an eval error for argument `{s}`: {s}\n", .{ arg, res.err.? });
            return error.ConsoleLeftEvalError;
        }

        // At least one log line is produced, even when the formatter has to fall back for a hostile value.
        if (g_log_capture.count() < 1) {
            std.debug.print("console." ++ method ++ " produced no log for argument `{s}`\n", .{arg});
            return error.ConsoleLoggedNothing;
        }

        // No pending exception survives in the runtime itself, not only in what the next evaluation reports.
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const pending = backend.ActiveEngineModule.qjs.JS_HasException(ctx);
            try testing.expect(if (@TypeOf(pending) == bool) !pending else pending == 0);
        }

        // The next evaluation is clean and so are promise jobs.
        try helpers.expectEvalEquals(id, "1 + 1", "2");
        try helpers.evalOk(id, "globalThis.__job = 0; Promise.resolve().then(function () { globalThis.__job = 1; });");
        try helpers.expectEvalEquals(id, "String(globalThis.__job)", "1");
    }
}

test "console: log of unserializable values leaves the engine usable" {
    try expectConsoleLeavesEngineClean("log");
}

test "console: error of unserializable values leaves the engine usable" {
    try expectConsoleLeavesEngineClean("error");
}

// The method set beyond these five differs by backend (the QuickJS family also exposes group, table, time, trace and others; JSC exposes only these), so only the common level methods are required.
test "console: the level methods are functions and the binding can be replaced" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    try helpers.expectEvalEquals(id,
        \\['log', 'info', 'warn', 'error', 'debug'].map(function (m) { return typeof console[m]; }).join(',')
    , "function,function,function,function,function");
    // The global binding itself is writable and configurable, so a script may shadow or delete it without breaking the engine.
    try helpers.expectEvalEquals(id,
        \\(function () {
        \\    var d = Object.getOwnPropertyDescriptor(globalThis, 'console');
        \\    return String(d.writable === true && d.configurable === true);
        \\})()
    , "true");
    try helpers.evalOk(id, "var saved = console; globalThis.console = undefined; globalThis.console = saved;");
    try helpers.expectEvalEquals(id, "typeof console.log", "function");
}

test "console: formatting does not depend on script-visible JSON" {
    g_log_capture = LogCapture.init();
    defer g_log_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &captureLog }));
    defer engine.destroy(id);

    try helpers.evalOk(id,
        \\JSON.stringify = function () { return 'HACKED'; };
        \\globalThis.JSON = { stringify: function () { return 'HACKED2'; } };
        \\console.log({ a: 1 });
    );
    try testing.expectEqual(@as(usize, 1), g_log_capture.count());
    const message = g_log_capture.messages.items[0];
    try testing.expect(std.mem.indexOf(u8, message, "\"a\":1") != null);
    try testing.expect(std.mem.indexOf(u8, message, "HACKED") == null);
}
