//! Tests for the console_tap side-channel.
//!
//! These tests verify that:
//! - A registered tap receives the same pre-formatted message that the log_handler receives, keyed by instance_id.
//! - All five console.* methods (log, debug, info, warn, error) dispatch with their expected LogLevel. Note the engine has four LogLevel values (debug/info/warn/err); `console.log` and `console.debug` both route at .debug. See `registerConsole` in the QuickJS backend.
//!   - `clear` stops delivery cleanly.
//!   - Registering a tap does NOT disturb the existing log_handler path.
//!   - Tap works even when no log_handler is installed on the engine.

const std = @import("std");
const sync = @import("zev");
const io = @import("../platform/io.zig");
const testing = std.testing;

const engine = @import("../engine.zig");
const types = @import("../types.zig");
const console_tap = @import("../inspector/console_tap.zig");
const helpers = @import("test_helpers.zig");

// ---------------------------------------------------------------------------
// Tap + log_handler capture state.
//
// TapCallback is `callconv(.c)` so it cannot close over Zig locals. We use a process-global capture struct, re-initialised at the top of each test.
// ---------------------------------------------------------------------------

const Capture = struct {
    tap_messages: std.ArrayList([]u8),
    tap_levels: std.ArrayList(types.LogLevel),
    tap_instance_ids: std.ArrayList(i32),
    handler_messages: std.ArrayList([]u8),
    handler_levels: std.ArrayList(types.LogLevel),
    mutex: sync.Mutex = .{},

    fn init() Capture {
        return .{
            .tap_messages = .empty,
            .tap_levels = .empty,
            .tap_instance_ids = .empty,
            .handler_messages = .empty,
            .handler_levels = .empty,
        };
    }

    fn deinit(self: *Capture) void {
        for (self.tap_messages.items) |m| std.heap.c_allocator.free(m);
        self.tap_messages.deinit(std.heap.c_allocator);
        self.tap_levels.deinit(std.heap.c_allocator);
        self.tap_instance_ids.deinit(std.heap.c_allocator);
        for (self.handler_messages.items) |m| std.heap.c_allocator.free(m);
        self.handler_messages.deinit(std.heap.c_allocator);
        self.handler_levels.deinit(std.heap.c_allocator);
        self.mutex.deinit();
    }

    fn tapCount(self: *Capture) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tap_messages.items.len;
    }

    fn handlerCount(self: *Capture) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.handler_messages.items.len;
    }
};

var g_capture: Capture = undefined;

fn tapCb(
    ctx: ?*anyopaque,
    instance_id: i32,
    level: types.LogLevel,
    message: [*:0]const u8,
) callconv(.c) void {
    _ = ctx;
    g_capture.mutex.lock();
    defer g_capture.mutex.unlock();
    const s = std.mem.span(message);
    const owned = std.heap.c_allocator.dupe(u8, s) catch return;
    g_capture.tap_messages.append(std.heap.c_allocator, owned) catch {
        std.heap.c_allocator.free(owned);
        return;
    };
    g_capture.tap_levels.append(std.heap.c_allocator, level) catch {};
    g_capture.tap_instance_ids.append(std.heap.c_allocator, instance_id) catch {};
}

fn handlerCb(
    instance_id: i32,
    level: types.LogLevel,
    message: [*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = instance_id;
    _ = user_data;
    g_capture.mutex.lock();
    defer g_capture.mutex.unlock();
    const s = std.mem.span(message);
    const owned = std.heap.c_allocator.dupe(u8, s) catch return;
    g_capture.handler_messages.append(std.heap.c_allocator, owned) catch {
        std.heap.c_allocator.free(owned);
        return;
    };
    g_capture.handler_levels.append(std.heap.c_allocator, level) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "console_tap: tap receives log after JS console.log" {
    g_capture = Capture.init();
    defer g_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &handlerCb }));
    defer {
        console_tap.clear(id);
        engine.destroy(id);
    }

    console_tap.set(id, null, &tapCb);

    try helpers.evalOk(id, "console.log('hello', 42)");

    try testing.expectEqual(@as(usize, 1), g_capture.tapCount());
    try testing.expectEqual(types.LogLevel.debug, g_capture.tap_levels.items[0]);
    try testing.expectEqual(id, g_capture.tap_instance_ids.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[0], "hello") != null);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[0], "42") != null);
}

test "console_tap: all five console methods dispatch with correct levels" {
    g_capture = Capture.init();
    defer g_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &handlerCb }));
    defer {
        console_tap.clear(id);
        engine.destroy(id);
    }

    console_tap.set(id, null, &tapCb);

    try helpers.evalOk(id,
        \\console.log('a');
        \\console.debug('b');
        \\console.info('c');
        \\console.warn('d');
        \\console.error('e');
    );

    try testing.expectEqual(@as(usize, 5), g_capture.tapCount());
    // console.log and console.debug both route to .debug (engine has no separate .log level — see types.zig and registerConsole).
    try testing.expectEqual(types.LogLevel.debug, g_capture.tap_levels.items[0]);
    try testing.expectEqual(types.LogLevel.debug, g_capture.tap_levels.items[1]);
    try testing.expectEqual(types.LogLevel.info, g_capture.tap_levels.items[2]);
    try testing.expectEqual(types.LogLevel.warn, g_capture.tap_levels.items[3]);
    try testing.expectEqual(types.LogLevel.err, g_capture.tap_levels.items[4]);

    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[0], "a") != null);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[1], "b") != null);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[2], "c") != null);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[3], "d") != null);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[4], "e") != null);
}

test "console_tap: clear stops delivery" {
    g_capture = Capture.init();
    defer g_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &handlerCb }));
    defer {
        console_tap.clear(id);
        engine.destroy(id);
    }

    console_tap.set(id, null, &tapCb);
    try helpers.evalOk(id, "console.log('first')");
    try testing.expectEqual(@as(usize, 1), g_capture.tapCount());

    console_tap.clear(id);
    try helpers.evalOk(id, "console.log('second')");
    // Tap must NOT have received the second message.
    try testing.expectEqual(@as(usize, 1), g_capture.tapCount());
    // log_handler however received both (tap is a side-channel).
    try testing.expectEqual(@as(usize, 2), g_capture.handlerCount());

    // clear is idempotent — second call is a no-op.
    console_tap.clear(id);
}

test "console_tap: existing log_handler still receives after tap added" {
    g_capture = Capture.init();
    defer g_capture.deinit();

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .log_handler = &handlerCb }));
    defer {
        console_tap.clear(id);
        engine.destroy(id);
    }

    console_tap.set(id, null, &tapCb);

    try helpers.evalOk(id, "console.warn('both')");

    try testing.expectEqual(@as(usize, 1), g_capture.tapCount());
    try testing.expectEqual(@as(usize, 1), g_capture.handlerCount());
    try testing.expectEqual(types.LogLevel.warn, g_capture.tap_levels.items[0]);
    try testing.expectEqual(types.LogLevel.warn, g_capture.handler_levels.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[0], "both") != null);
    try testing.expect(std.mem.indexOf(u8, g_capture.handler_messages.items[0], "both") != null);
}

test "console_tap: tap fires even when no log_handler is installed" {
    g_capture = Capture.init();
    defer g_capture.deinit();

    // Deliberately omit log_handler — the tap should still fire.
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer {
        console_tap.clear(id);
        engine.destroy(id);
    }

    console_tap.set(id, null, &tapCb);

    try helpers.evalOk(id, "console.info('lonely')");

    try testing.expectEqual(@as(usize, 1), g_capture.tapCount());
    try testing.expectEqual(@as(usize, 0), g_capture.handlerCount());
    try testing.expectEqual(types.LogLevel.info, g_capture.tap_levels.items[0]);
    try testing.expect(std.mem.indexOf(u8, g_capture.tap_messages.items[0], "lonely") != null);
}

const LeaseProbe = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release_callback: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(u32) = .init(0),

    fn acquire(ctx: ?*anyopaque) bool {
        const probe: *LeaseProbe = @ptrCast(@alignCast(ctx.?));
        _ = probe.held.fetchAdd(1, .seq_cst);
        return true;
    }

    fn release(ctx: ?*anyopaque) void {
        const probe: *LeaseProbe = @ptrCast(@alignCast(ctx.?));
        _ = probe.held.fetchSub(1, .seq_cst);
    }

    fn callback(ctx: ?*anyopaque, _: i32, _: types.LogLevel, _: [*:0]const u8) callconv(.c) void {
        const probe: *LeaseProbe = @ptrCast(@alignCast(ctx.?));
        probe.entered.store(true, .seq_cst);
        while (!probe.release_callback.load(.seq_cst)) std.Thread.yield() catch {};
    }

    fn fire(id: i32) void {
        console_tap.fire(id, .info, "lease-test");
    }
};

test "console_tap: clear leaves in-flight callback lease held until return" {
    const id = helpers.nextInstanceId();
    var probe: LeaseProbe = .{};
    console_tap.setLeased(id, &probe, LeaseProbe.callback, .{
        .acquire = LeaseProbe.acquire,
        .release = LeaseProbe.release,
    });
    const thread = try std.Thread.spawn(.{}, LeaseProbe.fire, .{id});
    const entered = spinUntil(&probe.entered, 5000);
    var held_while_callback_blocked: u32 = 0;
    if (entered) {
        console_tap.clear(id);
        held_while_callback_blocked = probe.held.load(.seq_cst);
    } else {
        console_tap.clear(id);
    }
    probe.release_callback.store(true, .seq_cst);
    thread.join();
    try testing.expect(entered);
    try testing.expectEqual(@as(u32, 1), held_while_callback_blocked);
    try testing.expectEqual(@as(u32, 0), probe.held.load(.seq_cst));
}

fn spinUntil(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const start = io.monotonicMilliseconds();
    while (!flag.load(.seq_cst)) {
        if (io.monotonicMilliseconds() - start >= timeout_ms) return false;
        io.sleepMs(1);
    }
    return true;
}
