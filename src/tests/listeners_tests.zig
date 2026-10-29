//! Tests for NamedListenerRegistry — backend-neutral listener management.
//!
//! Most tests exercise the registry directly against a bare runtime+context pair (no engine instance) because the registry operates purely on backend primitives (`ctx`, `Value`). The registered-instance lifecycle contract additionally covers destruction from a callback. Each bare-context test:
//!   1. opens a bare context,
//! 2. evaluates a small JS snippet that installs the test fixture functions as globals,
//!   3. pulls those functions out via `getGlobalObject` + `getPropertyVal`,
//!   4. drives the registry API,
//!   5. asserts on observable JS-side side effects (via a second eval).
//!
//! Every test either calls `registry.freeAll(ctx)` or explicitly tracks references so we don't leak JS values across test teardown.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const listeners = @import("../runtime/listeners.zig");
const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

// ----------------------------------------------------------------------------
// Small helpers local to this test file.
// ----------------------------------------------------------------------------

/// Install a JS function at `globalThis[name]` and return a retained reference that the caller must eventually free (or hand off to the registry).
fn installFn(
    ctx: ActiveEngine.Context,
    name_z: [*:0]const u8,
    body: []const u8,
) !ActiveEngine.Value {
    // Build a small script of the form: `globalThis.<name> = <body>;`
    var buf: [512]u8 = undefined;
    const script = std.fmt.bufPrint(
        &buf,
        "globalThis.{s} = {s};",
        .{ std.mem.span(name_z), body },
    ) catch return error.ScriptTooLong;

    const res = ActiveEngine.eval(ctx, script, "<install>");
    if (res.err != null) {
        helpers.freeEvalResult(res);
        return error.JSException;
    }
    helpers.freeEvalResult(res);

    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);

    return ActiveEngine.getPropertyVal(ctx, global, name_z) orelse return error.MissingFn;
}

/// Evaluate `expr` and return its stringified result. Caller frees via `std.heap.c_allocator.free`.
fn evalToString(
    ctx: ActiveEngine.Context,
    expr: []const u8,
) ![]const u8 {
    const res = ActiveEngine.eval(ctx, expr, "<read>");
    if (res.err != null) {
        helpers.freeEvalResult(res);
        return error.JSException;
    }
    return res.result orelse return error.NoResult;
}

/// Evaluate `expr` (which should produce a number) and return it as i32.
fn evalInt(ctx: ActiveEngine.Context, expr: []const u8) !i32 {
    const s = try evalToString(ctx, expr);
    defer std.heap.c_allocator.free(@constCast(s));
    return std.fmt.parseInt(i32, s, 10) catch error.NotAnInt;
}

// ============================================================================
// Tests
// ============================================================================

test "listeners: set returns true and has reports the name" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(ctx, "__l1", "(() => 42)");
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(registry.set(ctx, "a", fn_val));
            try testing.expect(registry.has("a"));
        }
    }.run);
}

test "listeners: set with empty name returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(ctx, "__l2", "(() => 0)");
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(!registry.set(ctx, "", fn_val));
            try testing.expect(!registry.has(""));
        }
    }.run);
}

test "listeners: set with MAX_NAME_LEN-sized name succeeds" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(ctx, "__l3", "(() => 0)");
            defer ActiveEngine.freeValue(ctx, fn_val);

            const name: [listeners.MAX_NAME_LEN]u8 = @splat('a');
            try testing.expectEqual(@as(usize, 31), name.len);
            try testing.expect(registry.set(ctx, &name, fn_val));
            try testing.expect(registry.has(&name));
        }
    }.run);
}

test "listeners: set with oversized name returns false" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(ctx, "__l4", "(() => 0)");
            defer ActiveEngine.freeValue(ctx, fn_val);

            const name: [listeners.MAX_NAME_LEN + 1]u8 = @splat('a');
            try testing.expect(!registry.set(ctx, &name, fn_val));
            try testing.expect(!registry.has(&name));
        }
    }.run);
}

test "listeners: set MAX_LISTENERS unique names fills registry; 17th fails" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(ctx, "__l5", "(() => 0)");
            defer ActiveEngine.freeValue(ctx, fn_val);

            var i: usize = 0;
            while (i < listeners.MAX_LISTENERS) : (i += 1) {
                var buf: [8]u8 = undefined;
                const name = std.fmt.bufPrint(&buf, "n{d}", .{i}) catch unreachable;
                try testing.expect(registry.set(ctx, name, fn_val));
            }
            try testing.expect(!registry.set(ctx, "overflow", fn_val));
            try testing.expect(!registry.has("overflow"));
        }
    }.run);
}

test "listeners: set with existing name replaces prior value" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            // Seed a JS global counter and two functions that tag which one ran.
            const setup = ActiveEngine.eval(
                ctx,
                \\globalThis.__which = 0;
                \\globalThis.__fa = () => { globalThis.__which = 1; };
                \\globalThis.__fb = () => { globalThis.__which = 2; };
            ,
                "<replace-setup>",
            );
            helpers.freeEvalResult(setup);
            if (setup.err != null) return error.JSException;

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);

            const fa = ActiveEngine.getPropertyVal(ctx, global, "__fa") orelse return error.MissingFn;
            defer ActiveEngine.freeValue(ctx, fa);
            const fb = ActiveEngine.getPropertyVal(ctx, global, "__fb") orelse return error.MissingFn;
            defer ActiveEngine.freeValue(ctx, fb);

            try testing.expect(registry.set(ctx, "dup", fa));
            try testing.expect(registry.set(ctx, "dup", fb));
            try testing.expect(registry.emit(ctx, "dup", &.{}));

            try testing.expectEqual(@as(i32, 2), try evalInt(ctx, "globalThis.__which"));
        }
    }.run);
}

test "listeners: remove clears entry; emit returns false afterwards" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(ctx, "__l7", "(() => { globalThis.__touched = 1; })");
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(registry.set(ctx, "x", fn_val));
            registry.remove(ctx, "x");
            try testing.expect(!registry.has("x"));
            try testing.expect(!registry.emit(ctx, "x", &.{}));
        }
    }.run);
}

test "listeners: remove on non-existent name is a no-op" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            // Should not crash or error.
            registry.remove(ctx, "never-set");
            try testing.expect(!registry.has("never-set"));
        }
    }.run);
}

test "listeners: emit with no args invokes stored function (JS side effect visible)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(
                ctx,
                "__l9",
                "(() => { globalThis.__mark = 777; })",
            );
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(registry.set(ctx, "evt", fn_val));
            try testing.expect(registry.emit(ctx, "evt", &.{}));
            try testing.expectEqual(@as(i32, 777), try evalInt(ctx, "globalThis.__mark"));
        }
    }.run);
}

test "listeners: emit forwards int and string arguments to the handler" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(
                ctx,
                "__l10",
                "((n, s) => { globalThis.__n = n; globalThis.__s = s; })",
            );
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(registry.set(ctx, "evt", fn_val));

            const args = [_]ActiveEngine.Value{
                ActiveEngine.newInt32Val(ctx, 123),
                ActiveEngine.newStringVal(ctx, "hello"),
            };
            defer for (args) |a| ActiveEngine.freeValue(ctx, a);

            try testing.expect(registry.emit(ctx, "evt", &args));

            try testing.expectEqual(@as(i32, 123), try evalInt(ctx, "globalThis.__n"));

            const s = try evalToString(ctx, "globalThis.__s");
            defer std.heap.c_allocator.free(@constCast(s));
            try testing.expectEqualStrings("hello", s);
        }
    }.run);
}

test "listeners: callRetained returns retained value (toInt32 == 42)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(ctx, "__l11", "(() => 42)");
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(registry.set(ctx, "q", fn_val));

            const result = registry.callRetained(ctx, "q", &.{}) orelse return error.NullResult;
            defer ActiveEngine.freeValue(ctx, result);

            const n = ActiveEngine.toInt32(ctx, result) orelse return error.NotAnInt;
            try testing.expectEqual(@as(i32, 42), n);
        }
    }.run);
}

test "listeners: callRetained on missing name returns null" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const r = registry.callRetained(ctx, "nope", &.{});
            try testing.expect(r == null);
        }
    }.run);
}

test "listeners: callRetained survives a native callback that destroys its registered instance" {
    const Probe = struct {
        registry: *listeners.NamedListenerRegistry,
        ctx: ActiveEngine.Context,
        fn callback(instance_id: i32, data: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            out_value.* = 0;
            out_exception.* = 0;
            // The registry is an external retained JS-value owner. Release its callback root before teardown so this contract isolates the host helper's lifetime, rather than leaking a fixture root.
            self.registry.remove(self.ctx, "destroy");
            engine.destroy(instance_id);
            return 4;
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    var registry = listeners.NamedListenerRegistry{};
    var probe = Probe{ .registry = &registry, .ctx = ctx };
    var native: u64 = 0;
    var exception: u64 = 0;
    const native_name = "__listener_destroy_from_callback__";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = native_name.ptr, .len = native_name.len }, Probe.callback, &probe, null, &native, &exception));

    const callback = try installFn(ctx, "__listener_lifetime_handler__", "(() => __listener_destroy_from_callback__())");
    try testing.expect(registry.set(ctx, "destroy", callback));
    ActiveEngine.freeValue(ctx, callback);

    try testing.expect(registry.callRetained(ctx, "destroy", &.{}) == null);
    try testing.expect(instance_map.getInstance(id) == null);
}

test "listeners: setOwner makes emitted function see `this` as the owner" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            // Function uses `this.marker` — must be a non-arrow function for `this` to be bindable via Call.
            const fn_val = try installFn(
                ctx,
                "__l13",
                "(function () { globalThis.owner_marker = this.marker; })",
            );
            defer ActiveEngine.freeValue(ctx, fn_val);

            // Build an owner object with marker=7 via eval, then grab it.
            const setup = ActiveEngine.eval(
                ctx,
                "globalThis.__owner = { marker: 7 };",
                "<owner-setup>",
            );
            helpers.freeEvalResult(setup);
            if (setup.err != null) return error.JSException;

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const owner = ActiveEngine.getPropertyVal(ctx, global, "__owner") orelse
                return error.MissingOwner;
            defer ActiveEngine.freeValue(ctx, owner);

            registry.setOwner(ctx, owner);
            try testing.expect(registry.set(ctx, "evt", fn_val));
            try testing.expect(registry.emit(ctx, "evt", &.{}));

            try testing.expectEqual(
                @as(i32, 7),
                try evalInt(ctx, "globalThis.owner_marker"),
            );
        }
    }.run);
}

test "listeners: freeAll drops all entries (has returns false)" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            // Not using defer here because the test itself exercises freeAll.

            const fn_val = try installFn(ctx, "__l14", "(() => 0)");
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(registry.set(ctx, "a", fn_val));
            try testing.expect(registry.set(ctx, "b", fn_val));
            try testing.expect(registry.set(ctx, "c", fn_val));

            registry.freeAll(ctx);

            try testing.expect(!registry.has("a"));
            try testing.expect(!registry.has("b"));
            try testing.expect(!registry.has("c"));

            // Second freeAll (and the implicit teardown) must still be safe.
            registry.freeAll(ctx);
        }
    }.run);
}

test "listeners: freeAll on an empty registry is a no-op" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            registry.freeAll(ctx);
            registry.freeAll(ctx); // double-free-all must also be safe.
            try testing.expect(!registry.has("anything"));
        }
    }.run);
}

test "listeners: set-freeAll-set round-trip works" {
    try helpers.withBareContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            var registry = listeners.NamedListenerRegistry{};
            defer registry.freeAll(ctx);

            const fn_val = try installFn(
                ctx,
                "__l16",
                "(() => { globalThis.__phase = (globalThis.__phase || 0) + 1; })",
            );
            defer ActiveEngine.freeValue(ctx, fn_val);

            try testing.expect(registry.set(ctx, "evt", fn_val));
            try testing.expect(registry.emit(ctx, "evt", &.{}));

            registry.freeAll(ctx);
            try testing.expect(!registry.has("evt"));

            try testing.expect(registry.set(ctx, "evt", fn_val));
            try testing.expect(registry.has("evt"));
            try testing.expect(registry.emit(ctx, "evt", &.{}));

            try testing.expectEqual(@as(i32, 2), try evalInt(ctx, "globalThis.__phase"));
        }
    }.run);
}
