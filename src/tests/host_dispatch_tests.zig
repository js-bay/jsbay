//! Tests for `host.GlobalHandler` + the `dispatch` module.
//!
//! Most tests operate directly on a bare runtime+context. The registered-instance lifecycle contract additionally verifies that a native callback may destroy its engine while a host helper is unwinding. The host layer is a thin wrapper over dispatch, so tests exercise both in tandem: we install JS globals via `ActiveEngine.eval`, invoke handlers through `host.global`, and assert on observable JS-side state (read back with a second eval).
//!
//! Every retained return value from `call`/`callRetained` is explicitly freed.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const host = @import("../runtime/host.zig");
const dispatch = @import("../runtime/dispatch.zig");
const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

// ----------------------------------------------------------------------------
// Local helpers.
// ----------------------------------------------------------------------------

fn installScript(ctx: ActiveEngine.Context, script: []const u8) !void {
    const res = ActiveEngine.eval(ctx, script, "<setup>");
    helpers.freeEvalResult(res);
    if (res.err != null) return error.JSException;
}

fn evalToString(ctx: ActiveEngine.Context, expr: []const u8) ![]const u8 {
    const res = ActiveEngine.eval(ctx, expr, "<read>");
    if (res.err != null) {
        helpers.freeEvalResult(res);
        return error.JSException;
    }
    return res.result orelse return error.NoResult;
}

fn evalInt(ctx: ActiveEngine.Context, expr: []const u8) !i32 {
    const s = try evalToString(ctx, expr);
    defer std.heap.c_allocator.free(@constCast(s));
    return std.fmt.parseInt(i32, s, 10) catch error.NotAnInt;
}

// ============================================================================
// Tests
// ============================================================================

test "host: global handler emit with no args invokes JS function" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(
                ctx,
                "globalThis.fn = () => { globalThis.mark = 1; };",
            );

            try testing.expect(host.global(ctx, "fn").emit(&.{}));
            try testing.expectEqual(@as(i32, 1), try evalInt(ctx, "globalThis.mark"));
        }
    }.run);
}

test "host: emit forwards typed args (int32/string/bool) and handler sees them" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(
                ctx,
                \\globalThis.fn = (n, s, b) => {
                \\  globalThis.__n = n;
                \\  globalThis.__s = s;
                \\  globalThis.__b = b;
                \\};
                ,
            );

            try testing.expect(host.global(ctx, "fn").emit(&.{
                .{ .int32 = 5 },
                .{ .string = "hi" },
                .{ .bool = true },
            }));

            try testing.expectEqual(@as(i32, 5), try evalInt(ctx, "globalThis.__n"));

            const s = try evalToString(ctx, "globalThis.__s");
            defer std.heap.c_allocator.free(@constCast(s));
            try testing.expectEqualStrings("hi", s);

            const b = try evalToString(ctx, "String(globalThis.__b)");
            defer std.heap.c_allocator.free(@constCast(b));
            try testing.expectEqualStrings("true", b);
        }
    }.run);
}

test "host: emitJson passes raw string (handler must JSON.parse it)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            // Handler captures the type + parsed value. If the bridge parsed JSON for us, `typeof payload` would be "object", not "string".
            try installScript(
                ctx,
                \\globalThis.fn = (payload) => {
                \\  globalThis.__type = typeof payload;
                \\  globalThis.__raw = payload;
                \\  globalThis.__parsed = JSON.parse(payload).a;
                \\};
                ,
            );

            try testing.expect(host.global(ctx, "fn").emitJson("{\"a\":1}"));

            const t = try evalToString(ctx, "globalThis.__type");
            defer std.heap.c_allocator.free(@constCast(t));
            try testing.expectEqualStrings("string", t);

            const raw = try evalToString(ctx, "globalThis.__raw");
            defer std.heap.c_allocator.free(@constCast(raw));
            try testing.expectEqualStrings("{\"a\":1}", raw);

            try testing.expectEqual(@as(i32, 1), try evalInt(ctx, "globalThis.__parsed"));
        }
    }.run);
}

test "host: emit on missing global returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try testing.expect(!host.global(ctx, "missing").emit(&.{}));
        }
    }.run);
}

test "host: emit on non-function global returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(ctx, "globalThis.nonfunc = 42;");
            try testing.expect(!host.global(ctx, "nonfunc").emit(&.{}));
        }
    }.run);
}

test "host: call returns non-null retained value and caller frees it" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(ctx, "globalThis.fn = (n) => n * 2;");

            const result = host.global(ctx, "fn").call(&.{.{ .int32 = 7 }}) orelse
                return error.NullResult;
            defer ActiveEngine.freeValue(ctx, result);

            const v = ActiveEngine.toInt32(ctx, result) orelse return error.NotAnInt;
            try testing.expectEqual(@as(i32, 14), v);
        }
    }.run);
}

test "host: callRetained accepts raw backend values and returns retained result" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(ctx, "globalThis.fn = (a, b) => a + b;");

            const raw = [_]ActiveEngine.Value{
                ActiveEngine.newInt32Val(ctx, 10),
                ActiveEngine.newInt32Val(ctx, 32),
            };
            defer for (raw) |v| ActiveEngine.freeValue(ctx, v);

            const result = host.global(ctx, "fn").callRetained(&raw) orelse
                return error.NullResult;
            defer ActiveEngine.freeValue(ctx, result);

            const v = ActiveEngine.toInt32(ctx, result) orelse return error.NotAnInt;
            try testing.expectEqual(@as(i32, 42), v);
        }
    }.run);
}

test "dispatch: DispatchArg marshals string/int32/bool to correct JS typeof" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(
                ctx,
                \\globalThis.fn = (a, b, c) => {
                \\  globalThis.r = typeof a + ':' + typeof b + ':' + typeof c;
                \\};
                ,
            );

            try testing.expect(dispatch.emitGlobal(ctx, "fn", &.{
                .{ .string = "x" },
                .{ .int32 = 1 },
                .{ .bool = false },
            }));

            const s = try evalToString(ctx, "globalThis.r");
            defer std.heap.c_allocator.free(@constCast(s));
            try testing.expectEqualStrings("string:number:boolean", s);
        }
    }.run);
}

test "dispatch: emitGlobal drains pending jobs (microtask runs before we read)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(
                ctx,
                \\globalThis.fn = () => {
                \\  Promise.resolve().then(() => { globalThis.p = 99; });
                \\};
                ,
            );

            try testing.expect(dispatch.emitGlobal(ctx, "fn", &.{}));
            try testing.expectEqual(@as(i32, 99), try evalInt(ctx, "globalThis.p"));
        }
    }.run);
}

test "dispatch: stress emit 1000 times — no leaks or crashes" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try installScript(
                ctx,
                \\globalThis.count = 0;
                \\globalThis.fn = (n) => { globalThis.count += n; };
                ,
            );

            var i: i32 = 0;
            while (i < 1000) : (i += 1) {
                try testing.expect(dispatch.emitGlobal(ctx, "fn", &.{.{ .int32 = 1 }}));
            }

            try testing.expectEqual(@as(i32, 1000), try evalInt(ctx, "globalThis.count"));
        }
    }.run);
}

test "host: emitJson survives a native callback that destroys its registered instance" {
    const Destroy = struct {
        fn callback(instance_id: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            out_value.* = 0;
            out_exception.* = 0;
            engine.destroy(instance_id);
            return 4;
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    var native: u64 = 0;
    var exception: u64 = 0;
    const native_name = "__host_destroy_from_callback__";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = native_name.ptr, .len = native_name.len }, Destroy.callback, null, null, &native, &exception));
    try installScript(ctx, "globalThis.__host_lifetime_handler__ = () => __host_destroy_from_callback__();");

    try testing.expect(!host.global(ctx, "__host_lifetime_handler__").emitJson("{}"));
    try testing.expect(instance_map.getInstance(id) == null);
}
