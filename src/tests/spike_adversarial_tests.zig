//! Hostile edge cases against spike in-scope surfaces via the public C ABI / SDK.
//! Escargot: ESM + shared core. Hermes: .hbc + shared core.
//! Out of scope (CJS / inspector / engine_thread) is not expanded here.
const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");
const c_api = @import("../c_api.zig");

const API_OK: c_int = 0;
const API_EXCEPTION: c_int = 1;
fn spikeOnly() !void {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
}

fn utf8(s: []const u8) c_api.Utf8 {
    return .{ .data = s.ptr, .len = s.len };
}

fn createEngine() !i32 {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    return id;
}

fn destroyEngine(id: i32) void {
    c_api.jsbay_engine_destroy(id);
}

fn withPublicEngine(comptime run: fn (i32) anyerror!void) !void {
    const id = try createEngine();
    defer destroyEngine(id);
    try run(id);
}

fn releaseValue(v: u64) void {
    if (v != 0) _ = c_api.jsbay_value_release(v);
}

fn evaluate(id: i32, source: []const u8, filename: []const u8) !struct { status: c_int, value: u64, exception: u64 } {
    var value: u64 = 0;
    var exception: u64 = 0;
    const status = c_api.jsbay_engine_evaluate(id, utf8(source), utf8(filename), null, &value, &exception);
    return .{ .status = status, .value = value, .exception = exception };
}

fn evalOk(id: i32, source: []const u8) !void {
    const r = try evaluate(id, source, "<test>");
    defer releaseValue(r.value);
    defer releaseValue(r.exception);
    try testing.expectEqual(API_OK, r.status);
    try testing.expectEqual(@as(u64, 0), r.exception);
}

fn evalErr(id: i32, source: []const u8) !void {
    const r = try evaluate(id, source, "<test>");
    defer releaseValue(r.value);
    defer releaseValue(r.exception);
    if (r.status == API_EXCEPTION or r.exception != 0) return;
    // Spike value-eval may publish a thrown Error as the result value when err text is unavailable.
    if (r.status == API_OK and r.value != 0) {
        var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
        var to_exc: u64 = 0;
        if (c_api.jsbay_value_to_utf8(r.value, &bytes, &to_exc) == API_OK) {
            defer c_api.jsbay_free_bytes(bytes);
            defer releaseValue(to_exc);
            const actual = if (bytes.data) |ptr| ptr[0..bytes.len] else "";
            if (std.mem.indexOf(u8, actual, "Error") != null or std.mem.indexOf(u8, actual, "error") != null or
                std.mem.indexOf(u8, actual, "Syntax") != null or std.mem.indexOf(u8, actual, "Unexpected") != null)
                return;
        } else {
            releaseValue(to_exc);
        }
    }
    return error.ExpectedException;
}

fn expectEvalEquals(id: i32, source: []const u8, expected: []const u8) !void {
    const r = try evaluate(id, source, "<test>");
    defer releaseValue(r.value);
    defer releaseValue(r.exception);
    try testing.expectEqual(API_OK, r.status);
    try testing.expectEqual(@as(u64, 0), r.exception);
    var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
    var to_exc: u64 = 0;
    try testing.expectEqual(API_OK, c_api.jsbay_value_to_utf8(r.value, &bytes, &to_exc));
    defer c_api.jsbay_free_bytes(bytes);
    defer releaseValue(to_exc);
    const actual = if (bytes.data) |p| p[0..bytes.len] else "";
    try testing.expectEqualStrings(expected, actual);
}

fn advance(id: i32, ms: i64) void {
    _ = c_api.test_only.advance(id, ms);
}

// ---- malformed / empty inputs ----

test "adversarial: empty and whitespace-only eval" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            {
                const r = try evaluate(id, "", "<empty>");
                defer releaseValue(r.value);
                defer releaseValue(r.exception);
            }
            {
                const r = try evaluate(id, "   \n\t  ", "<ws>");
                defer releaseValue(r.value);
                defer releaseValue(r.exception);
            }
            try expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "adversarial: malformed syntax does not poison engine" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalErr(id, "function (");
            try evalErr(id, "}}}{{{");
            try evalErr(id, "'unterminated");
            try expectEvalEquals(id, "2*3", "6");
        }
    }.run);
}

test "adversarial: eval on dead instance returns error not crash" {
    try spikeOnly();
    const id = helpers.nextInstanceId();
    const r = try evaluate(id, "1", "<dead>");
    defer releaseValue(r.value);
    defer releaseValue(r.exception);
    try testing.expect(r.status != API_OK);
}

// ---- value / NUL ----

test "adversarial: embedded NUL in string roundtrip via eval" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id, "globalThis.__nul = 'a\\u0000b';");
            try expectEvalEquals(id, "globalThis.__nul.length", "3");
            try expectEvalEquals(id, "globalThis.__nul.charCodeAt(1)", "0");
        }
    }.run);
}

test "adversarial: property name with unusual characters" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id, "globalThis['x y'] = 7; globalThis[''] = 9;");
            try expectEvalEquals(id, "globalThis['x y']", "7");
            try expectEvalEquals(id, "globalThis['']", "9");
        }
    }.run);
}

// ---- Promise via public evaluate ----

test "adversarial: Promise double-then settle is safe" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\globalThis.__got = [];
                \\const p = Promise.resolve(1);
                \\p.then(v => { globalThis.__got.push(v); });
                \\p.then(v => { globalThis.__got.push(v + 1); });
            );
            advance(id, 0);
            try expectEvalEquals(id, "String(globalThis.__got)", "1,2");
        }
    }.run);
}

test "adversarial: Promise reject then catch is safe" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\globalThis.__got = 'no';
                \\Promise.reject('boom').then(() => {}, e => { globalThis.__got = String(e); });
            );
            advance(id, 0);
            try expectEvalEquals(id, "globalThis.__got", "boom");
            try expectEvalEquals(id, "3+4", "7");
        }
    }.run);
}

// ---- timers ----

test "adversarial: clearTimeout of unknown id is no-op" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id, "clearTimeout(999999); clearInterval(0); clearTimeout(-1);");
            try expectEvalEquals(id, "'ok'", "ok");
        }
    }.run);
}

test "adversarial: setTimeout zero delay still fires via drain" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\globalThis.__t = 0;
                \\setTimeout(() => { globalThis.__t = 1; }, 0);
            );
            advance(id, 50);
            try expectEvalEquals(id, "String(globalThis.__t)", "1");
        }
    }.run);
}

test "adversarial: nested setTimeout during destroy does not use-after-free" {
    try spikeOnly();
    const id = try createEngine();
    try evalOk(id,
        \\setTimeout(() => {
        \\  setTimeout(() => { globalThis.__x = 1; }, 0);
        \\}, 0);
    );
    destroyEngine(id);
}

// ---- public bind host callback ----

fn bindThrowGet(instance_id: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_value.* = 0;
    var err: u64 = 0;
    _ = c_api.jsbay_value_new_error(instance_id, utf8("hostile get"), &err);
    out_exception.* = err;
    return API_EXCEPTION;
}

test "adversarial: public bind throw leaves engine usable" {
    try spikeOnly();
    const id = try createEngine();
    defer destroyEngine(id);
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "ho";
    try testing.expectEqual(API_OK, c_api.jsbay_engine_bind(
        id,
        utf8(name),
        bindThrowGet,
        null,
        null,
        &function,
        &exception,
    ));
    defer releaseValue(function);
    defer releaseValue(exception);
    try evalErr(id, "ho()");
    try expectEvalEquals(id, "1+1", "2");
}

// ---- typed arrays ----

test "adversarial: zero-length TypedArray via eval" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try expectEvalEquals(id, "new Uint8Array(0).length", "0");
            try expectEvalEquals(id, "new Float64Array(0).byteLength", "0");
            try expectEvalEquals(id, "new ArrayBuffer(0).byteLength", "0");
        }
    }.run);
}

test "adversarial: TypedArray out-of-range index is undefined not crash" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try expectEvalEquals(id, "String(new Uint8Array([1])[99])", "undefined");
            try expectEvalEquals(id, "String(new Uint8Array([1])[-1])", "undefined");
        }
    }.run);
}

// ---- Escargot ESM via evaluate (module syntax may error without loader; must not crash) ----

test "adversarial: Escargot ESM empty module and syntax error" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            {
                const r = try evaluate(id, "", "<empty-mod>");
                defer releaseValue(r.value);
                defer releaseValue(r.exception);
            }
            try evalErr(id, "export const x = ;");
            try expectEvalEquals(id, "5", "5");
        }
    }.run);
}

test "adversarial: Escargot import without loader fails cleanly" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalErr(id, "import { x } from 'missing';");
            try expectEvalEquals(id, "9", "9");
        }
    }.run);
}

// ---- Hermes .hbc via public bytecode ABI ----

test "adversarial: Hermes empty source via public evaluate" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            // Public typed bytecode ABI is QuickJS-only; exercise empty/hostile source via evaluate.
            {
                const r = try evaluate(id, "", "<empty>");
                defer releaseValue(r.value);
                defer releaseValue(r.exception);
            }
            try expectEvalEquals(id, "1", "1");
        }
    }.run);
}

test "adversarial: Hermes run truncated/malformed .hbc" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            var garbage = [_]u8{ 0xc6, 0x1f, 0xbc, 0x03, 0x00, 0x00, 0x00, 0x00 };
            var value: u64 = 0;
            var exception: u64 = 0;
            const st = c_api.jsbay_engine_run_bytecode(id, &garbage, garbage.len, &value, &exception);
            defer releaseValue(value);
            defer releaseValue(exception);
            try testing.expect(st != API_OK);
            try expectEvalEquals(id, "2", "2");

            const empty: []const u8 = &[_]u8{};
            var value2: u64 = 0;
            var exception2: u64 = 0;
            const st2 = c_api.jsbay_engine_run_bytecode(id, empty.ptr, empty.len, &value2, &exception2);
            defer releaseValue(value2);
            defer releaseValue(exception2);
            try testing.expect(st2 != API_OK);
            try expectEvalEquals(id, "3", "3");
        }
    }.run);
}

test "adversarial: Hermes public bytecode ABI compile and run" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            // Hermes exposes hermesc .hbc through the public compile/run bytecode ABI.
            var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
            var exception: u64 = 0;
            const st = c_api.jsbay_engine_compile_bytecode(id, utf8("1+1"), utf8("<bc>"), &bytes, &exception);
            defer c_api.jsbay_free_bytes(bytes);
            defer releaseValue(exception);
            try testing.expectEqual(API_OK, st);
            try testing.expect(bytes.data != null);
            try testing.expect(bytes.len > 0);
            try testing.expect(exception == 0);

            var value: u64 = 0;
            var run_exc: u64 = 0;
            const run_st = c_api.jsbay_engine_run_bytecode(id, bytes.data, bytes.len, &value, &run_exc);
            defer releaseValue(value);
            defer releaseValue(run_exc);
            try testing.expectEqual(API_OK, run_st);
            try testing.expect(run_exc == 0);
            var utf: c_api.Bytes = .{ .data = null, .len = 0 };
            var to_exc: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_to_utf8(value, &utf, &to_exc));
            defer c_api.jsbay_free_bytes(utf);
            defer releaseValue(to_exc);
            const actual = if (utf.data) |ptr| ptr[0..utf.len] else "";
            try testing.expectEqualStrings("2", actual);
            try expectEvalEquals(id, "3", "3");
        }
    }.run);
}

// ---- rapid create/destroy / GC pressure ----

test "adversarial: rapid create destroy cycles" {
    try spikeOnly();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const id = try createEngine();
        try expectEvalEquals(id, "1", "1");
        destroyEngine(id);
    }
}

test "adversarial: many short-lived objects then GC" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\for (let i = 0; i < 100; i++) {
                \\  globalThis['k'+i] = { a: i, b: new Array(10).fill(i) };
                \\}
                \\for (let i = 0; i < 100; i++) delete globalThis['k'+i];
            );
            _ = c_api.jsbay_engine_run_gc(id);
            try expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "adversarial: ops on wrong instance id after destroy" {
    try spikeOnly();
    const id = try createEngine();
    destroyEngine(id);
    const r = try evaluate(id, "1", "<post-destroy>");
    defer releaseValue(r.value);
    defer releaseValue(r.exception);
    try testing.expect(r.status != API_OK);
    _ = c_api.jsbay_engine_run_gc(id);
}

// ---- deeper hostility ----

test "adversarial: throw null/undefined/number does not poison" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalErr(id, "throw null");
            try evalErr(id, "throw undefined");
            try evalErr(id, "throw 0");
            try evalErr(id, "throw ''");
            try expectEvalEquals(id, "7", "7");
        }
    }.run);
}

test "adversarial: Promise resolve with undefined via public evaluate" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\globalThis.__got = 'no';
                \\Promise.resolve(undefined).then(v => { globalThis.__got = String(v); });
            );
            advance(id, 0);
            try expectEvalEquals(id, "globalThis.__got", "undefined");
        }
    }.run);
}

test "adversarial: setInterval cleared from inside callback" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\globalThis.__n = 0;
                \\globalThis.__id = setInterval(() => {
                \\  globalThis.__n++;
                \\  clearInterval(globalThis.__id);
                \\}, 0);
            );
            advance(id, 50);
            advance(id, 50);
            advance(id, 50);
            try expectEvalEquals(id, "String(globalThis.__n)", "1");
        }
    }.run);
}

test "adversarial: very long identifier and string literal" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            var buf: [4200]u8 = undefined;
            @memset(buf[0..], 'a');
            const src = try std.fmt.allocPrint(std.heap.c_allocator, "globalThis.__s = '{s}'; __s.length", .{buf[0..4000]});
            defer std.heap.c_allocator.free(src);
            try expectEvalEquals(id, src, "4000");
        }
    }.run);
}

test "adversarial: ArrayBuffer slice views share memory" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\const b = new ArrayBuffer(4);
                \\const u = new Uint8Array(b);
                \\const v = new Uint8Array(b, 1, 2);
                \\u[1] = 9;
                \\globalThis.__x = v[0];
            );
            try expectEvalEquals(id, "String(globalThis.__x)", "9");
        }
    }.run);
}

test "adversarial: Escargot re-eval after failure" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalErr(id, "throw new Error('entry-fail');");
            {
                const r = try evaluate(id, "globalThis.__ok = 1;", "<ok>");
                defer releaseValue(r.value);
                defer releaseValue(r.exception);
            }
            try expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "adversarial: Hermes two instances isolated via public evaluate" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    const a = try createEngine();
    defer destroyEngine(a);
    const b = try createEngine();
    defer destroyEngine(b);
    try evalOk(a, "globalThis.__from = 11;");
    try expectEvalEquals(a, "String(globalThis.__from)", "11");
    try expectEvalEquals(b, "typeof globalThis.__from", "undefined");
}

test "adversarial: recursive JSON-like deep object" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\let o = {};
                \\for (let i = 0; i < 200; i++) o = { nest: o, i };
                \\globalThis.__depth = 0;
                \\let cur = o;
                \\while (cur && cur.nest) { globalThis.__depth++; cur = cur.nest; }
            );
            try expectEvalEquals(id, "String(globalThis.__depth)", "200");
        }
    }.run);
}

test "adversarial: Promise thenable storm then drain" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id,
                \\globalThis.__c = 0;
                \\let p = Promise.resolve(0);
                \\for (let i = 0; i < 50; i++) p = p.then(v => { globalThis.__c++; return v+1; });
                \\p.then(v => { globalThis.__final = v; });
            );
            var n: usize = 0;
            while (n < 60) : (n += 1) {
                advance(id, 0);
            }
            try expectEvalEquals(id, "String(globalThis.__c)", "50");
            try expectEvalEquals(id, "String(globalThis.__final)", "50");
        }
    }.run);
}

test "adversarial: double destroy is safe" {
    try spikeOnly();
    const id = try createEngine();
    destroyEngine(id);
    destroyEngine(id);
    const r = try evaluate(id, "1", "<after-double-destroy>");
    defer releaseValue(r.value);
    defer releaseValue(r.exception);
    try testing.expect(r.status != API_OK);
}

test "adversarial: setProperty rejects key with embedded NUL" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            var global: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_engine_global(id, &global));
            defer releaseValue(global);
            var num: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_new_number(id, 1, &num));
            defer releaseValue(num);
            const key = "a\x00b";
            var exception: u64 = 0;
            const st = c_api.jsbay_value_set(global, utf8(key), num, &exception);
            defer releaseValue(exception);
            try testing.expect(st != API_OK);
            try expectEvalEquals(id, "1", "1");
        }
    }.run);
}

test "adversarial: Hermes evaluate filename with spaces and metacharacters" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            const r = try evaluate(id, "1+2", "weird name; rm -rf / &.js");
            defer releaseValue(r.value);
            defer releaseValue(r.exception);
            try testing.expectEqual(API_OK, r.status);
            var utf: c_api.Bytes = .{ .data = null, .len = 0 };
            var to_exc: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_to_utf8(r.value, &utf, &to_exc));
            defer c_api.jsbay_free_bytes(utf);
            defer releaseValue(to_exc);
            const actual = if (utf.data) |ptr| ptr[0..utf.len] else "";
            try testing.expectEqualStrings("3", actual);
        }
    }.run);
}

test "adversarial: Hermes evaluate with empty filename" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            const r = try evaluate(id, "40+2", "");
            defer releaseValue(r.value);
            defer releaseValue(r.exception);
            try testing.expectEqual(API_OK, r.status);
            var utf: c_api.Bytes = .{ .data = null, .len = 0 };
            var to_exc: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_to_utf8(r.value, &utf, &to_exc));
            defer c_api.jsbay_free_bytes(utf);
            defer releaseValue(to_exc);
            const actual = if (utf.data) |ptr| ptr[0..utf.len] else "";
            try testing.expectEqualStrings("42", actual);
        }
    }.run);
}

test "adversarial: undefined sentinel to_utf8 is undefined" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            var und: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_undefined(id, &und));
            defer releaseValue(und);
            var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
            var exception: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_to_utf8(und, &bytes, &exception));
            defer c_api.jsbay_free_bytes(bytes);
            defer releaseValue(exception);
            const actual = if (bytes.data) |p| p[0..bytes.len] else "";
            try testing.expectEqualStrings("undefined", actual);
        }
    }.run);
}

test "adversarial: delete ignores replaced Reflect.deleteProperty" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id, "globalThis.__o = { a: 1 }; Reflect.deleteProperty = () => true;");
            var global: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_engine_global(id, &global));
            defer releaseValue(global);
            var obj: u64 = 0;
            var get_exc: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_get(global, utf8("__o"), &obj, &get_exc));
            defer releaseValue(obj);
            defer releaseValue(get_exc);
            var deleted: bool = false;
            var del_exc: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_delete(obj, utf8("a"), &deleted, &del_exc));
            defer releaseValue(del_exc);
            try testing.expect(deleted);
            try expectEvalEquals(id, "String(globalThis.__o.a)", "undefined");
        }
    }.run);
}

test "adversarial: primitive get ignores replaced Object" {
    try spikeOnly();
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalOk(id, "Object = function(){ return { length: 99 }; };");
            var str: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_new_string(id, utf8("abc"), &str));
            defer releaseValue(str);
            var len: u64 = 0;
            var exception: u64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_get(str, utf8("length"), &len, &exception));
            defer releaseValue(len);
            defer releaseValue(exception);
            var number: f64 = 0;
            try testing.expectEqual(API_OK, c_api.jsbay_value_to_number(len, &number));
            try testing.expectEqual(@as(f64, 3), number);
        }
    }.run);
}

test "adversarial: Hermes large-source evaluate" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            var pad: [5000]u8 = undefined;
            @memset(&pad, ' ');
            const prefix = "globalThis.__cache_probe__ = 4242; //";
            var src_buf: [5200]u8 = undefined;
            @memcpy(src_buf[0..prefix.len], prefix);
            @memcpy(src_buf[prefix.len .. prefix.len + pad.len], &pad);
            const src = src_buf[0 .. prefix.len + pad.len];
            try evalOk(id, src);
            try expectEvalEquals(id, "String(globalThis.__cache_probe__)", "4242");
        }
    }.run);
}

test "adversarial: Hermes malformed .hbc with random bytes" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            const junk = [_]u8{ 0x48, 0x42, 0x43, 0x00, 0xff, 0xfe, 0xfd, 0x01, 0x02, 0x03 };
            var value: u64 = 0;
            var exception: u64 = 0;
            const st = c_api.jsbay_engine_run_bytecode(id, &junk, junk.len, &value, &exception);
            defer releaseValue(value);
            defer releaseValue(exception);
            try testing.expect(st != API_OK);
            try expectEvalEquals(id, "'ok'", "ok");
        }
    }.run);
}

test "adversarial: Escargot relative import fails cleanly" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try withPublicEngine(struct {
        fn run(id: i32) !void {
            try evalErr(id, "import './x.js';");
            try expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

