//! Direct eval is refused once the engine thread is running.
//!
//! Before `threadStart`, and after `threadStop`, the calling thread may eval. After a successful start, any other thread's `evalScript` / `evalModule` fails without running the script. The same source still runs on the engine thread through `postScript` + `waitJob`.

const std = @import("std");
const testing = std.testing;

const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const helpers = @import("test_helpers.zig");

fn expectPosted(id: i32, src: []const u8, expected: []const u8) !void {
    const job = engine_thread.postScript(id, src, "<posted>");
    try testing.expect(job != 0);
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = engine_thread.waitJob(id, job, 5_000, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    if (status != engine_thread.status_ok) {
        const msg = if (err) |p| std.mem.span(p) else "";
        std.debug.print("posted status={d} err={s}\n", .{ status, msg });
    }
    try testing.expectEqual(engine_thread.status_ok, status);
    const text = std.mem.span(result orelse return error.MissingResult);
    try testing.expectEqualStrings(expected, text);
}

test "engine thread guard: caller eval succeeds before threadStart" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try helpers.expectEvalEquals(id, "1+1", "2");
    try helpers.evalOk(id, "globalThis.marker = 0;");
    try helpers.expectEvalEquals(id, "globalThis.marker", "0");
}

test "engine thread guard: foreign evalScript and evalModule do not run" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer {
        engine_thread.threadStop(id);
        engine.destroy(id);
    }

    try helpers.evalOk(id, "globalThis.marker = 0;");
    try testing.expect(engine_thread.threadStart(id));

    const blocked = engine.evalScript(id, "globalThis.marker = 1; 1", "<foreign>");
    defer helpers.freeEvalResult(blocked);
    try testing.expect(blocked.result == null);
    try testing.expectEqualStrings(engine_thread.foreign_eval_err, blocked.err orelse return error.MissingError);

    // The refused script must not have written the global.
    try expectPosted(id, "globalThis.marker", "0");

    const blocked_mod = engine.evalModule(id, "globalThis.marker = 9;\n", "<foreign-module>");
    defer helpers.freeEvalResult(blocked_mod);
    try testing.expect(blocked_mod.result == null);
    try testing.expectEqualStrings(engine_thread.foreign_eval_err, blocked_mod.err orelse return error.MissingError);
    try expectPosted(id, "globalThis.marker", "0");

    // The same source runs on the engine thread and its result is visible.
    try expectPosted(id, "globalThis.marker = 1; 1", "1");
    try expectPosted(id, "globalThis.marker", "1");
}
