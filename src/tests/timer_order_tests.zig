//! Ordering and bookkeeping of JavaScript timers under self-cancellation and nesting.
//!
//! The scripts keep all state in plain JavaScript values, so the same tests run on every backend.

const std = @import("std");
const testing = std.testing;

const engine = @import("../engine.zig");
const io = @import("../platform/io.zig");
const helpers = @import("test_helpers.zig");

/// Drive the event loop until `condition` evaluates to "true" or the turn cap is reached.
fn pumpUntil(id: i32, condition: []const u8) !void {
    var turn: u32 = 0;
    while (turn < 400) : (turn += 1) {
        engine.runEventLoopOnce(id);
        const res = engine.evalScript(id, condition, "<pump>");
        defer helpers.freeEvalResult(res);
        if (res.err != null) return error.JSException;
        if (res.result) |text| if (std.mem.eql(u8, text, "true")) return;
        io.sleepMs(1);
    }
    return error.TimedOut;
}

fn pumpTurns(id: i32, turns: u32) void {
    var turn: u32 = 0;
    while (turn < turns) : (turn += 1) {
        engine.runEventLoopOnce(id);
        io.sleepMs(1);
    }
}

test "timer order: one-shot timers that clear themselves leave 64 siblings firing once each in order" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__fired = [];
                \\globalThis.__ids = [];
                \\for (var i = 0; i < 64; i++) {
                \\  (function (n) {
                \\    __ids[n] = setTimeout(function () {
                \\      __fired.push(n);
                \\      // The timer is already running; clearing its own id must not disturb the rest.
                \\      clearTimeout(__ids[n]);
                \\    }, 0);
                \\  })(i);
                \\}
            );
            try pumpUntil(id, "String(__fired.length >= 64)");
            // Extra turns would expose a duplicate or a late firing.
            pumpTurns(id, 20);

            var expected: [64 * 3]u8 = undefined;
            var writer = std.Io.Writer.fixed(&expected);
            for (0..64) |n| {
                if (n > 0) try writer.writeByte(',');
                try writer.print("{d}", .{n});
            }
            try helpers.expectEvalEquals(id, "String(__fired.length)", "64");
            try helpers.expectEvalEquals(id, "__fired.join(',')", writer.buffered());
        }
    }.run);
}

test "timer order: three nested timer levels interleave with their microtasks" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__seq = [];
                \\setTimeout(function () {
                \\  __seq.push('a1');
                \\  Promise.resolve().then(function () { __seq.push('m1'); });
                \\  setTimeout(function () {
                \\    __seq.push('b1');
                \\    Promise.resolve().then(function () {
                \\      __seq.push('m2');
                \\      queueMicrotask(function () { __seq.push('m3'); });
                \\    });
                \\    setTimeout(function () {
                \\      __seq.push('c1');
                \\      Promise.resolve().then(function () { __seq.push('m4'); });
                \\    }, 0);
                \\  }, 0);
                \\}, 0);
                \\setTimeout(function () { __seq.push('a2'); }, 0);
            );
            try pumpUntil(id, "String(__seq.length >= 8)");
            pumpTurns(id, 10);
            // A timer's microtasks drain before the next timer of the same turn starts; a timer created inside a callback waits for a later turn than its already queued siblings.
            try helpers.expectEvalEquals(id, "__seq.join(',')", "a1,m1,a2,b1,m2,m3,c1,m4");
        }
    }.run);
}
