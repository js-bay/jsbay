//! Typed Value ABI object operations: construct, has, delete, keys and instance_of.
//!
//! Every case drives the public C exports so all three backends must agree on ECMAScript results, thrown values, status codes and zeroed outputs.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");
const rc = @import("../runtime/runtime_control.zig");

const ok: c_int = 0;
const thrown: c_int = 1;
const invalid_argument: c_int = 2;
const wrong_thread: c_int = 3;
const instance_not_found: c_int = 4;
const stale_value: c_int = 5;
const out_of_memory: c_int = 6;

/// Output slots are poisoned before each call to prove the API clears them.
const poison: u64 = 0xdead;

fn utf8(text: []const u8) c_api.Utf8 {
    return .{ .data = text.ptr, .len = text.len };
}

const Fixture = struct {
    id: i32,
    owned: std.ArrayList(u64) = .empty,

    fn init() !Fixture {
        const id = helpers.nextInstanceId();
        try testing.expect(c_api.jsbay_engine_create(id, null, null));
        return .{ .id = id };
    }

    fn deinit(self: *Fixture) void {
        for (self.owned.items) |handle| _ = c_api.jsbay_value_release(handle);
        self.owned.deinit(testing.allocator);
        c_api.jsbay_engine_destroy(self.id);
    }

    /// Track a handle so the fixture releases it exactly once.
    fn keep(self: *Fixture, handle: u64) !u64 {
        try testing.expect(handle != 0 and handle != poison);
        try self.owned.append(testing.allocator, handle);
        return handle;
    }

    fn eval(self: *Fixture, source: []const u8) !u64 {
        var value: u64 = poison;
        var exception: u64 = poison;
        const status = c_api.jsbay_engine_evaluate(self.id, utf8(source), utf8("object-ops.js"), null, &value, &exception);
        if (status != ok) {
            if (exception != 0 and exception != poison) _ = c_api.jsbay_value_release(exception);
            return error.EvaluateFailed;
        }
        return self.keep(value);
    }

    /// Evaluate without fixture ownership; the caller releases the handle.
    fn evalUntracked(self: *Fixture, source: []const u8) !u64 {
        var value: u64 = poison;
        var exception: u64 = poison;
        try testing.expectEqual(ok, c_api.jsbay_engine_evaluate(self.id, utf8(source), utf8("object-ops.js"), null, &value, &exception));
        try testing.expect(value != 0 and value != poison);
        return value;
    }

    fn number(self: *Fixture, input: f64) !u64 {
        var value: u64 = poison;
        try testing.expectEqual(ok, c_api.jsbay_value_new_number(self.id, input, &value));
        return self.keep(value);
    }

    fn string(self: *Fixture, input: []const u8) !u64 {
        var value: u64 = poison;
        try testing.expectEqual(ok, c_api.jsbay_value_new_string(self.id, utf8(input), &value));
        return self.keep(value);
    }

    fn get(self: *Fixture, object: u64, key: []const u8) !u64 {
        var value: u64 = poison;
        var exception: u64 = poison;
        try testing.expectEqual(ok, c_api.jsbay_value_get(object, utf8(key), &value, &exception));
        try testing.expectEqual(@as(u64, 0), exception);
        return self.keep(value);
    }

    fn text(_: *Fixture, handle: u64) ![]u8 {
        var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
        var exception: u64 = poison;
        try testing.expectEqual(ok, c_api.jsbay_value_to_utf8(handle, &bytes, &exception));
        try testing.expectEqual(@as(u64, 0), exception);
        defer c_api.jsbay_free_bytes(bytes);
        const data = bytes.data orelse return testing.allocator.alloc(u8, 0);
        return testing.allocator.dupe(u8, data[0..bytes.len]);
    }

    fn expectText(self: *Fixture, handle: u64, expected: []const u8) !void {
        const actual = try self.text(handle);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }

    fn expectJson(_: *Fixture, handle: u64, expected: []const u8) !void {
        var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
        var exception: u64 = poison;
        try testing.expectEqual(ok, c_api.jsbay_value_to_json(handle, &bytes, &exception));
        defer c_api.jsbay_free_bytes(bytes);
        try testing.expectEqualStrings(expected, (bytes.data orelse return error.MissingJson)[0..bytes.len]);
    }

    fn construct(_: *Fixture, function: u64, args: []const u64, out_value: *u64, out_exception: *u64) c_int {
        out_value.* = poison;
        out_exception.* = poison;
        return c_api.jsbay_value_construct(function, if (args.len == 0) null else args.ptr, args.len, out_value, out_exception);
    }

    /// `new function(...args)` that must succeed; the instance is fixture-owned.
    fn constructOk(self: *Fixture, function: u64, args: []const u64) !u64 {
        var value: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(ok, self.construct(function, args, &value, &exception));
        try testing.expectEqual(@as(u64, 0), exception);
        return self.keep(value);
    }

    /// Consume a thrown value and return its `name`, or "" when it has none.
    fn thrownName(self: *Fixture, exception: u64) ![]u8 {
        _ = try self.keep(exception);
        const name = try self.get(exception, "name");
        return self.text(name);
    }

    fn expectThrownTypeError(self: *Fixture, exception: u64) !void {
        const name = try self.thrownName(exception);
        defer testing.allocator.free(name);
        try testing.expectEqualStrings("TypeError", name);
    }

    fn has(_: *Fixture, object: u64, key: []const u8, out_has: *bool, out_exception: *u64) c_int {
        out_has.* = true;
        out_exception.* = poison;
        return c_api.jsbay_value_has(object, utf8(key), out_has, out_exception);
    }

    fn expectHas(self: *Fixture, object: u64, key: []const u8, expected: bool) !void {
        var found = !expected;
        var exception: u64 = 0;
        try testing.expectEqual(ok, self.has(object, key, &found, &exception));
        try testing.expectEqual(expected, found);
        try testing.expectEqual(@as(u64, 0), exception);
    }

    fn delete(_: *Fixture, object: u64, key: []const u8, out_deleted: *bool, out_exception: *u64) c_int {
        out_deleted.* = true;
        out_exception.* = poison;
        return c_api.jsbay_value_delete(object, utf8(key), out_deleted, out_exception);
    }

    fn expectDeleted(self: *Fixture, object: u64, key: []const u8, expected: bool) !void {
        var deleted = !expected;
        var exception: u64 = 0;
        try testing.expectEqual(ok, self.delete(object, key, &deleted, &exception));
        try testing.expectEqual(expected, deleted);
        try testing.expectEqual(@as(u64, 0), exception);
    }

    fn keys(_: *Fixture, object: u64, out_array: *u64, out_exception: *u64) c_int {
        out_array.* = poison;
        out_exception.* = poison;
        return c_api.jsbay_value_keys(object, out_array, out_exception);
    }

    fn expectKeys(self: *Fixture, object: u64, expected_json: []const u8) !void {
        var array: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(ok, self.keys(object, &array, &exception));
        try testing.expectEqual(@as(u64, 0), exception);
        _ = try self.keep(array);
        try self.expectJson(array, expected_json);
    }

    fn instanceOf(_: *Fixture, value: u64, constructor: u64, out_result: *bool, out_exception: *u64) c_int {
        out_result.* = true;
        out_exception.* = poison;
        return c_api.jsbay_value_instance_of(value, constructor, out_result, out_exception);
    }

    fn expectInstanceOf(self: *Fixture, value: u64, constructor: u64, expected: bool) !void {
        var result = !expected;
        var exception: u64 = 0;
        try testing.expectEqual(ok, self.instanceOf(value, constructor, &result, &exception));
        try testing.expectEqual(expected, result);
        try testing.expectEqual(@as(u64, 0), exception);
    }
};

/// Native callback that destroys its own instance while the engine call that invoked it is still running.
fn destroyInstanceCallback(instance_id: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    c_api.jsbay_engine_destroy(instance_id);
    return invalid_argument;
}

/// Installs `destroyNow()` and returns a value built by `source`, which calls it from inside a user-code hook.
fn destroyHookTarget(f: *Fixture, source: []const u8) !u64 {
    var function: u64 = poison;
    var exception: u64 = poison;
    try testing.expectEqual(ok, c_api.jsbay_engine_bind(f.id, utf8("destroyNow"), destroyInstanceCallback, null, null, &function, &exception));
    _ = try f.keep(function);
    return f.eval(source);
}

test "object ops: construct reports a missing instance when a constructor destroys it" {
    // Spike: jsbay_engine_bind trampoline via makeNativeFunction (api_bind.spikeInstall).
    var f = try Fixture.init();
    defer f.deinit();
    const target = try destroyHookTarget(&f, "(function F() { destroyNow(); })");
    var value: u64 = poison;
    var exception: u64 = poison;
    try testing.expectEqual(instance_not_found, f.construct(target, &.{}, &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
    try testing.expectEqual(@as(u64, 0), exception);
    try testing.expectEqual(stale_value, f.construct(target, &.{}, &value, &exception));
}

test "object ops: has reports a missing instance when a Proxy trap destroys it" {
    // Spike: jsbay_engine_bind trampoline via makeNativeFunction (api_bind.spikeInstall).
    var f = try Fixture.init();
    defer f.deinit();
    const target = try destroyHookTarget(&f, "new Proxy({}, { has() { destroyNow(); return true; } })");
    var found = true;
    var exception: u64 = poison;
    try testing.expectEqual(instance_not_found, f.has(target, "a", &found, &exception));
    try testing.expect(!found);
    try testing.expectEqual(@as(u64, 0), exception);
}

test "object ops: delete reports a missing instance when a Proxy trap destroys it" {
    // Spike: jsbay_engine_bind trampoline via makeNativeFunction (api_bind.spikeInstall).
    var f = try Fixture.init();
    defer f.deinit();
    const target = try destroyHookTarget(&f, "new Proxy({ a: 1 }, { deleteProperty() { destroyNow(); return true; } })");
    var deleted = true;
    var exception: u64 = poison;
    try testing.expectEqual(instance_not_found, f.delete(target, "a", &deleted, &exception));
    try testing.expect(!deleted);
    try testing.expectEqual(@as(u64, 0), exception);
}

test "object ops: keys reports a missing instance when a Proxy trap destroys it" {
    // Spike: jsbay_engine_bind trampoline via makeNativeFunction (api_bind.spikeInstall).
    var f = try Fixture.init();
    defer f.deinit();
    const target = try destroyHookTarget(&f, "new Proxy({ a: 1 }, { ownKeys() { destroyNow(); return ['a']; } })");
    var array: u64 = poison;
    var exception: u64 = poison;
    try testing.expectEqual(instance_not_found, f.keys(target, &array, &exception));
    try testing.expectEqual(@as(u64, 0), array);
    try testing.expectEqual(@as(u64, 0), exception);
}

test "object ops: instance_of reports a missing instance when Symbol.hasInstance destroys it" {
    // Spike: jsbay_engine_bind trampoline via makeNativeFunction (api_bind.spikeInstall).
    var f = try Fixture.init();
    defer f.deinit();
    const target = try destroyHookTarget(&f, "({ [Symbol.hasInstance]() { destroyNow(); return true; } })");
    const subject = try f.eval("({})");
    var result = true;
    var exception: u64 = poison;
    try testing.expectEqual(instance_not_found, f.instanceOf(subject, target, &result, &exception));
    try testing.expect(!result);
    try testing.expectEqual(@as(u64, 0), exception);
}

test "object ops: every operation called off the owner thread reports wrong thread and clears outputs" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval("({ a: 1 })");
    const constructor = try f.eval("(function F() {})");

    const Probe = struct {
        fixture: *Fixture,
        object: u64,
        constructor: u64,
        statuses: [5]c_int = @splat(-1),
        leaked: bool = true,

        fn run(self: *@This()) void {
            var value: u64 = poison;
            var exception: u64 = poison;
            var flag = true;
            var leaked = false;

            self.statuses[0] = self.fixture.construct(self.constructor, &.{}, &value, &exception);
            leaked = leaked or value != 0 or exception != 0;
            self.statuses[1] = self.fixture.has(self.object, "a", &flag, &exception);
            leaked = leaked or flag or exception != 0;
            flag = true;
            self.statuses[2] = self.fixture.delete(self.object, "a", &flag, &exception);
            leaked = leaked or flag or exception != 0;
            self.statuses[3] = self.fixture.keys(self.object, &value, &exception);
            leaked = leaked or value != 0 or exception != 0;
            flag = true;
            self.statuses[4] = self.fixture.instanceOf(self.object, self.constructor, &flag, &exception);
            leaked = leaked or flag or exception != 0;
            self.leaked = leaked;
        }
    };
    var probe: Probe = .{ .fixture = &f, .object = object, .constructor = constructor };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();

    for (probe.statuses) |status| try testing.expectEqual(wrong_thread, status);
    try testing.expect(!probe.leaked);
    // The rejected calls must not have touched the object.
    try f.expectHas(object, "a", true);
}

test "object ops: construct builds class instances that report instance_of" {
    var f = try Fixture.init();
    defer f.deinit();
    const A = try f.eval("(class A { constructor(x) { this.x = x; } })");
    const seven = try f.number(7);
    const instance = try f.constructOk(A, &.{seven});
    try f.expectText(try f.get(instance, "x"), "7");
    try f.expectInstanceOf(instance, A, true);

    const no_args = try f.constructOk(try f.eval("(function F() { this.made = true; })"), &.{});
    try f.expectText(try f.get(no_args, "made"), "true");
}

test "object ops: construct supports builtin constructors" {
    var f = try Fixture.init();
    defer f.deinit();
    const Map = try f.eval("Map");
    const entries = try f.eval("[['a', 1], ['b', 2]]");
    const map = try f.constructOk(Map, &.{entries});
    try f.expectText(try f.get(map, "size"), "2");
    try f.expectInstanceOf(map, Map, true);

    const Date = try f.eval("Date");
    const epoch_day = try f.number(86400000);
    const date = try f.constructOk(Date, &.{epoch_day});
    try f.expectInstanceOf(date, Date, true);
    const to_iso = try f.get(date, "toISOString");
    var iso: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_call(to_iso, date, null, 0, &iso, &exception));
    try f.expectText(try f.keep(iso), "1970-01-02T00:00:00.000Z");
}

test "object ops: construct reports non-constructors and constructor throws as exceptions" {
    var f = try Fixture.init();
    defer f.deinit();
    var value: u64 = 0;
    var exception: u64 = 0;

    const non_constructors = [_][]const u8{ "(() => 1)", "({})", "42", "undefined", "null", "Math.max.bind(null)" };
    for (non_constructors) |source| {
        const target = try f.eval(source);
        try testing.expectEqual(thrown, f.construct(target, &.{}, &value, &exception));
        try testing.expectEqual(@as(u64, 0), value);
        try f.expectThrownTypeError(exception);
    }
    // Method shorthand and async functions have no [[Construct]] either.
    // Hermes (with ES6Class) still treats concise methods as constructible — engine limit.
    const method_and_async = if (comptime backend.active_backend == .hermes)
        [_][]const u8{"(async function () {})"}
    else
        [_][]const u8{ "({ m() {} }).m", "(async function () {})" };
    for (method_and_async) |source| {
        const target = try f.eval(source);
        try testing.expectEqual(thrown, f.construct(target, &.{}, &value, &exception));
        try testing.expectEqual(@as(u64, 0), value);
        try f.expectThrownTypeError(exception);
    }

    const throws_number = try f.eval("(class T { constructor() { throw 42; } })");
    try testing.expectEqual(thrown, f.construct(throws_number, &.{}, &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
    _ = try f.keep(exception);
    var as_number: f64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_to_number(exception, &as_number));
    try testing.expectEqual(@as(f64, 42), as_number);

    const throws_object = try f.eval("(function () { throw { code: 'E' }; })");
    try testing.expectEqual(thrown, f.construct(throws_object, &.{}, &value, &exception));
    _ = try f.keep(exception);
    try f.expectText(try f.get(exception, "code"), "E");
}

test "object ops: construct honors bound functions and Proxy construct traps" {
    var f = try Fixture.init();
    defer f.deinit();
    const bound = try f.eval("(function A(x, y) { this.sum = x + y; }).bind(null, 1)");
    const two = try f.eval("2");
    const instance = try f.constructOk(bound, &.{two});
    try f.expectJson(instance, "{\"sum\":3}");

    const proxied = try f.eval("new Proxy(function () {}, { construct(_, args) { return { n: args.length }; } })");
    const instance_from_trap = try f.constructOk(proxied, &.{ two, two });
    try f.expectJson(instance_from_trap, "{\"n\":2}");

    const bad_trap = try f.eval("new Proxy(function () {}, { construct() { return 1; } })");
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(thrown, f.construct(bad_trap, &.{}, &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
    try f.expectThrownTypeError(exception);
}

test "object ops: construct validates arguments and handles" {
    var f = try Fixture.init();
    defer f.deinit();
    const A = try f.eval("(class A {})");
    var value: u64 = poison;
    var exception: u64 = poison;
    try testing.expectEqual(invalid_argument, c_api.jsbay_value_construct(A, null, 1, &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
    try testing.expectEqual(@as(u64, 0), exception);

    const stale: u64 = 0x7fff_ffff_ffff;
    try testing.expectEqual(stale_value, f.construct(stale, &.{}, &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
    try testing.expectEqual(@as(u64, 0), exception);

    const bogus_args = [_]u64{stale};
    try testing.expectEqual(stale_value, f.construct(A, &bogus_args, &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
}

test "object ops: has sees own and inherited properties but not missing ones" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval("(function () { const proto = { inherited: 1 }; const o = Object.create(proto); o.own = 2; o[Symbol('tag')] = 3; o[7] = 4; return o; })()");
    try f.expectHas(object, "own", true);
    try f.expectHas(object, "inherited", true);
    try f.expectHas(object, "toString", true);
    try f.expectHas(object, "missing", false);
    try f.expectHas(object, "7", true);
    // A string key never matches a Symbol-keyed property.
    try f.expectHas(object, "tag", false);
    try f.expectHas(object, "Symbol(tag)", false);

    const array = try f.eval("[10, 20]");
    try f.expectHas(array, "1", true);
    try f.expectHas(array, "2", false);
    try f.expectHas(array, "length", true);

    const proxy = try f.eval("new Proxy({}, { has(_, key) { return key === 'virtual'; } })");
    try f.expectHas(proxy, "virtual", true);
    try f.expectHas(proxy, "other", false);
}

test "object ops: has throws a TypeError for non-objects and propagates trap exceptions" {
    var f = try Fixture.init();
    defer f.deinit();
    var found = true;
    var exception: u64 = 0;
    for ([_][]const u8{ "5", "undefined", "null", "'text'", "true" }) |source| {
        const target = try f.eval(source);
        try testing.expectEqual(thrown, f.has(target, "length", &found, &exception));
        try testing.expect(!found);
        try f.expectThrownTypeError(exception);
    }

    const trap = try f.eval("new Proxy({}, { has() { throw 'trap'; } })");
    try testing.expectEqual(thrown, f.has(trap, "k", &found, &exception));
    try testing.expect(!found);
    _ = try f.keep(exception);
    try f.expectText(exception, "trap");
}

test "object ops: has and delete reject invalid keys" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval("({ a: 1 })");
    const bad_keys = [_][]const u8{ "\xff", "\xc3", "a\x00b", "\x00" };
    for (bad_keys) |key| {
        var flag = true;
        var exception: u64 = poison;
        try testing.expectEqual(invalid_argument, f.has(object, key, &flag, &exception));
        try testing.expect(!flag);
        try testing.expectEqual(@as(u64, 0), exception);
        flag = true;
        exception = poison;
        try testing.expectEqual(invalid_argument, f.delete(object, key, &flag, &exception));
        try testing.expect(!flag);
        try testing.expectEqual(@as(u64, 0), exception);
    }
    try f.expectHas(object, "a", true);

    var flag = true;
    var exception: u64 = poison;
    try testing.expectEqual(invalid_argument, c_api.jsbay_value_has(object, .{ .data = null, .len = 1 }, &flag, &exception));
    try testing.expect(!flag);
    // An empty key is valid and names the "" property.
    try f.expectHas(object, "", false);
    try testing.expectEqual(stale_value, f.has(0x7fff_ffff_ffff, "a", &flag, &exception));
    try testing.expect(!flag and exception == 0);
}

test "object ops: delete removes configurable properties and reports refusals without throwing" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval("(function () { const o = { plain: 1 }; Object.defineProperty(o, 'locked', { value: 1, enumerable: true }); return o; })()");

    try f.expectDeleted(object, "plain", true);
    try f.expectHas(object, "plain", false);

    try f.expectDeleted(object, "locked", false);
    try f.expectHas(object, "locked", true);

    try f.expectDeleted(object, "never_existed", true);

    const frozen = try f.eval("Object.freeze({ a: 1 })");
    try f.expectDeleted(frozen, "a", false);
    try f.expectHas(frozen, "a", true);
    try f.expectDeleted(frozen, "absent", true);

    const sealed = try f.eval("Object.seal({ a: 1 })");
    try f.expectDeleted(sealed, "a", false);

    const array = try f.eval("[1, 2, 3]");
    try f.expectDeleted(array, "1", true);
    try f.expectHas(array, "1", false);
    try f.expectDeleted(array, "length", false);
}

test "object ops: delete follows ToObject for primitives and propagates trap exceptions" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.expectDeleted(try f.number(5), "x", true);
    try f.expectDeleted(try f.string("abc"), "length", false);

    var deleted = true;
    var exception: u64 = 0;
    for ([_][]const u8{ "undefined", "null" }) |source| {
        const target = try f.eval(source);
        try testing.expectEqual(thrown, f.delete(target, "x", &deleted, &exception));
        try testing.expect(!deleted);
        try f.expectThrownTypeError(exception);
    }

    const trap = try f.eval("new Proxy({ a: 1 }, { deleteProperty() { throw 'delete-trap'; } })");
    try testing.expectEqual(thrown, f.delete(trap, "a", &deleted, &exception));
    try testing.expect(!deleted);
    _ = try f.keep(exception);
    try f.expectText(exception, "delete-trap");

    const refusing = try f.eval("new Proxy({ a: 1 }, { deleteProperty() { return false; } })");
    try f.expectDeleted(refusing, "a", false);
}

test "object ops: keys follows Object.keys ordering and filters" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval(
        \\(function () {
        \\  const proto = { inherited: 1 };
        \\  const o = Object.create(proto);
        \\  o.b = 1; o[10] = 1; o.a = 1; o[2] = 1; o[Symbol('s')] = 1;
        \\  Object.defineProperty(o, 'hidden', { value: 1, enumerable: false });
        \\  o.z = 1;
        \\  return o;
        \\})()
    );
    try f.expectKeys(object, "[\"2\",\"10\",\"b\",\"a\",\"z\"]");

    try f.expectKeys(try f.eval("[10, 20, 30]"), "[\"0\",\"1\",\"2\"]");
    try f.expectKeys(try f.eval("(function () { const a = [1]; a.extra = 1; return a; })()"), "[\"0\",\"extra\"]");
    try f.expectKeys(try f.eval("({})"), "[]");
    try f.expectKeys(try f.eval("(function () { const o = Object.create({ onlyInherited: 1 }); return o; })()"), "[]");
    try f.expectKeys(try f.eval("new Proxy({ p: 1, q: 2 }, {})"), "[\"p\",\"q\"]");
    try f.expectKeys(try f.eval("(function f(a, b) {})"), "[]");
}

test "object ops: keys follows ToObject for primitives and propagates trap exceptions" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.expectKeys(try f.string("ab"), "[\"0\",\"1\"]");
    try f.expectKeys(try f.number(5), "[]");

    var array: u64 = poison;
    var exception: u64 = 0;
    for ([_][]const u8{ "undefined", "null" }) |source| {
        const target = try f.eval(source);
        try testing.expectEqual(thrown, f.keys(target, &array, &exception));
        try testing.expectEqual(@as(u64, 0), array);
        try f.expectThrownTypeError(exception);
    }

    const trap = try f.eval("new Proxy({ a: 1 }, { ownKeys() { throw 'keys-trap'; } })");
    try testing.expectEqual(thrown, f.keys(trap, &array, &exception));
    try testing.expectEqual(@as(u64, 0), array);
    _ = try f.keep(exception);
    try f.expectText(exception, "keys-trap");

    try testing.expectEqual(stale_value, f.keys(0x7fff_ffff_ffff, &array, &exception));
    try testing.expect(array == 0 and exception == 0);
}

test "object ops: results do not depend on page-replaced intrinsics" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval("({ real: 1 })");
    _ = try f.eval(
        \\Object.keys = function () { return ['forged']; };
        \\Object.getOwnPropertyNames = Object.keys;
        \\Reflect.ownKeys = Object.keys;
        \\globalThis.TypeError = function () {};
        \\true
    );
    try f.expectKeys(object, "[\"real\"]");
    var found = true;
    var exception: u64 = 0;
    try testing.expectEqual(thrown, f.has(try f.number(5), "x", &found, &exception));
    try f.expectThrownTypeError(exception);
    var value: u64 = 0;
    try testing.expectEqual(thrown, f.construct(try f.eval("({})"), &.{}, &value, &exception));
    try f.expectThrownTypeError(exception);
}

test "object ops: keys defines result elements without running Array.prototype setters" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval("({ a: 1, b: 2 })");
    _ = try f.eval(
        \\globalThis.setterHits = 0;
        \\Object.defineProperty(Array.prototype, '0', { set(v) { globalThis.setterHits++; }, configurable: true });
        \\true
    );
    var array: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(ok, f.keys(object, &array, &exception));
    _ = try f.keep(array);
    try f.expectText(try f.eval("globalThis.setterHits"), "0");
    // JSON.stringify in QuickJS keeps its own stack in an array, so remove the trap before serializing the result.
    _ = try f.eval("delete Array.prototype[0]; true");
    try f.expectJson(array, "[\"a\",\"b\"]");
}

test "object ops: instance_of covers positive, negative, inheritance and hasInstance" {
    var f = try Fixture.init();
    defer f.deinit();
    const Base = try f.eval("(globalThis.Base = class Base {})");
    const Derived = try f.eval("(globalThis.Derived = class Derived extends Base {})");
    const derived = try f.constructOk(Derived, &.{});
    try f.expectInstanceOf(derived, Derived, true);
    try f.expectInstanceOf(derived, Base, true);
    const base = try f.constructOk(Base, &.{});
    try f.expectInstanceOf(base, Derived, false);
    try f.expectInstanceOf(try f.eval("({})"), Base, false);
    try f.expectInstanceOf(try f.eval("[]"), try f.eval("Array"), true);
    try f.expectInstanceOf(try f.eval("[]"), try f.eval("Object"), true);

    // Primitives are never instances, even of their wrapper constructors.
    try f.expectInstanceOf(try f.number(5), try f.eval("Number"), false);
    try f.expectInstanceOf(try f.eval("undefined"), try f.eval("Object"), false);

    const custom = try f.eval("({ [Symbol.hasInstance](v) { return v === 1; } })");
    try f.expectInstanceOf(try f.number(1), custom, true);
    try f.expectInstanceOf(try f.number(2), custom, false);
    const class_with_static = try f.eval("(class Even { static [Symbol.hasInstance](v) { return v % 2 === 0; } })");
    try f.expectInstanceOf(try f.number(4), class_with_static, true);
    try f.expectInstanceOf(try f.number(3), class_with_static, false);
}

test "object ops: instance_of throws for non-callable constructors and hasInstance throws" {
    var f = try Fixture.init();
    defer f.deinit();
    var result = true;
    var exception: u64 = 0;
    const value = try f.eval("({})");
    for ([_][]const u8{ "({})", "1", "undefined", "null", "'text'" }) |source| {
        const target = try f.eval(source);
        try testing.expectEqual(thrown, f.instanceOf(value, target, &result, &exception));
        try testing.expect(!result);
        try f.expectThrownTypeError(exception);
    }

    const hostile = try f.eval("({ [Symbol.hasInstance]() { throw 'has-instance'; } })");
    try testing.expectEqual(thrown, f.instanceOf(value, hostile, &result, &exception));
    try testing.expect(!result);
    _ = try f.keep(exception);
    try f.expectText(exception, "has-instance");

    try testing.expectEqual(stale_value, f.instanceOf(0x7fff_ffff_ffff, value, &result, &exception));
    try testing.expect(!result and exception == 0);
    try testing.expectEqual(stale_value, f.instanceOf(value, 0x7fff_ffff_ffff, &result, &exception));
    try testing.expect(!result and exception == 0);
}

test "object ops: handles are released and operations reject released handles" {
    var f = try Fixture.init();
    defer f.deinit();
    var object: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_new_object(f.id, &object));
    var array: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(ok, f.keys(object, &array, &exception));
    try testing.expectEqual(ok, c_api.jsbay_value_release(array));
    // The array handle is gone for good; operating on it is STALE_VALUE.
    var flag = true;
    try testing.expectEqual(stale_value, f.has(array, "length", &flag, &exception));
    try testing.expectEqual(stale_value, c_api.jsbay_value_release(array));
    try testing.expectEqual(ok, c_api.jsbay_value_release(object));
    try testing.expectEqual(stale_value, f.has(object, "a", &flag, &exception));
}

test "object ops: key allocation failure reports out of memory and clears outputs" {
    var f = try Fixture.init();
    defer f.deinit();
    const object = try f.eval("({ a: 1 })");
    var flag = true;
    var exception: u64 = poison;

    c_api.test_only.failNextKeyAllocation();
    try testing.expectEqual(out_of_memory, f.has(object, "a", &flag, &exception));
    try testing.expect(!flag);
    try testing.expectEqual(@as(u64, 0), exception);

    c_api.test_only.failNextKeyAllocation();
    try testing.expectEqual(out_of_memory, f.delete(object, "a", &flag, &exception));
    try testing.expect(!flag);
    try testing.expectEqual(@as(u64, 0), exception);

    // Neither failed call may have touched the property.
    try f.expectHas(object, "a", true);
    try f.expectDeleted(object, "a", true);
}

const Sweep = struct {
    fixture: *Fixture,
    class: u64,
    object: u64,
    argument: u64,
    ok_count: usize = 0,
    /// Failures per operation, indexed in `run` order.
    failures: [5]usize = @splat(0),

    fn record(self: *Sweep, op: usize, status: c_int) !void {
        switch (status) {
            ok => self.ok_count += 1,
            thrown, out_of_memory => self.failures[op] += 1,
            else => return error.UnexpectedStatus,
        }
    }

    fn failureCount(self: *const Sweep) usize {
        var total: usize = 0;
        for (self.failures) |count| total += count;
        return total;
    }

    fn run(self: *Sweep) !void {
        var value: u64 = 0;
        var exception: u64 = 0;
        var flag = false;

        var status = self.fixture.construct(self.class, &.{self.argument}, &value, &exception);
        try self.record(0, status);
        try expectPair(status, value, exception);
        release(value);
        release(exception);

        status = self.fixture.keys(self.object, &value, &exception);
        try self.record(1, status);
        try expectPair(status, value, exception);
        release(value);
        release(exception);

        status = self.fixture.has(self.object, "k1", &flag, &exception);
        try self.record(2, status);
        try expectFlag(status, flag, exception);
        release(exception);

        status = self.fixture.delete(self.object, "k2", &flag, &exception);
        try self.record(3, status);
        try expectFlag(status, flag, exception);
        release(exception);

        status = self.fixture.instanceOf(self.object, self.class, &flag, &exception);
        try self.record(4, status);
        try expectFlag(status, flag, exception);
        release(exception);
    }

    fn release(handle: u64) void {
        if (handle != 0 and handle != poison) _ = c_api.jsbay_value_release(handle);
    }

    fn expectPair(status: c_int, value: u64, exception: u64) !void {
        switch (status) {
            ok => try testing.expect(value != 0 and exception == 0),
            thrown => try testing.expect(value == 0 and exception != 0),
            else => try testing.expect(value == 0 and exception == 0),
        }
    }

    fn expectFlag(status: c_int, flag: bool, exception: u64) !void {
        switch (status) {
            ok => try testing.expect(exception == 0),
            thrown => try testing.expect(!flag and exception != 0),
            else => try testing.expect(!flag and exception == 0),
        }
    }
};

test "object ops: memory pressure yields only typed statuses and leaks no objects" {
    var f = try Fixture.init();
    defer f.deinit();
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) {
        // JSC exposes no heap cap, so allocation pressure cannot be injected.
        try testing.expect(!c_api.jsbay_engine_set_memory_limit(f.id, 1));
        return;
    }
    var sweep: Sweep = .{
        .fixture = &f,
        .class = try f.eval("(class C { constructor(n) { this.items = new Array(n).fill(0); } })"),
        .object = 0,
        .argument = try f.number(500),
    };
    // Large enough that the result array and the instance's storage exceed the free blocks of the allocator's arenas, so small headrooms must fail.
    const object_source = "(() => { const o = {}; for (let i = 0; i < 400; i++) o['k' + i] = i; return o; })()";

    // Warm lazily created intrinsics, then take the baseline.
    sweep.object = try f.evalUntracked(object_source);
    try sweep.run();
    Sweep.release(sweep.object);
    _ = rc.runGc(f.id);
    const settled = rc.getMemoryUsage(f.id) orelse return error.NoUsage;

    const headrooms = [_]u64{ 0, 16, 64, 160, 400, 1000, 3000, 10_000 };
    for (headrooms) |headroom| {
        sweep.object = try f.evalUntracked(object_source);
        _ = rc.runGc(f.id);
        const usage = rc.getMemoryUsage(f.id) orelse return error.NoUsage;
        try testing.expect(c_api.jsbay_engine_set_memory_limit(f.id, usage.malloc_size + headroom));
        try sweep.run();
        try testing.expect(c_api.jsbay_engine_set_memory_limit(f.id, 0));
        Sweep.release(sweep.object);
    }
    try testing.expect(sweep.ok_count > 0);
    try testing.expect(sweep.failures[0] > 0); // construct
    try testing.expect(sweep.failures[1] > 0); // keys

    // Same engine, lifted limit: every operation succeeds again.
    sweep.object = try f.evalUntracked(object_source);
    const failures_before = sweep.failureCount();
    try sweep.run();
    try testing.expectEqual(failures_before, sweep.failureCount());
    Sweep.release(sweep.object);

    _ = rc.runGc(f.id);
    const after = rc.getMemoryUsage(f.id) orelse return error.NoUsage;
    try testing.expectEqual(settled.obj_count, after.obj_count);
}
