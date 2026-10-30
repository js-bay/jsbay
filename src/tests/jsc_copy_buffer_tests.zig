const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");

const ok: c_int = 0;
const invalid: c_int = 2;

fn evaluate(id: i32, source: []const u8, out: *u64) !void {
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = "copy.js", .len = 7 }, null, out, &exception));
    try testing.expectEqual(@as(u64, 0), exception);
}

fn expectInvalid(value: u64) !void {
    var bytes = c_api.Bytes{ .data = @ptrFromInt(1), .len = 99 };
    var exception: u64 = 99;
    try testing.expectEqual(invalid, c_api.jsbay_value_copy_buffer(value, &bytes, &exception));
    try testing.expect(bytes.data == null and bytes.len == 0 and exception == 0);
}

fn expectBytes(value: u64, expected: []const u8) !void {
    var bytes = c_api.Bytes{ .data = null, .len = 0 };
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_copy_buffer(value, &bytes, &exception));
    defer c_api.jsbay_free_bytes(bytes);
    try testing.expectEqual(@as(u64, 0), exception);
    try testing.expectEqualSlices(u8, expected, bytes.data.?[0..bytes.len]);
}

test "JSC copy buffer rejects genuinely detached buffers without mutable hooks" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var ab: u64 = 0;
    var ta: u64 = 0;
    var dv: u64 = 0;
    var zero_ab: u64 = 0;
    var zero_ta: u64 = 0;
    var sub: u64 = 0;
    defer {
        for ([_]*u64{ &ab, &ta, &dv, &zero_ab, &zero_ta, &sub }) |value| {
            if (value.* != 0) _ = c_api.jsbay_value_release(value.*);
        }
    }

    const setup =
        "globalThis.ab=new ArrayBuffer(4);globalThis.ta=new Uint8Array(ab);globalThis.dv=new DataView(ab);ta.set([1,2,3,4]);" ++
        "globalThis.live=new ArrayBuffer(4);new Uint8Array(live).set([5,6,7,8]);globalThis.sub=new Uint8Array(live,1,2);" ++
        "globalThis.zero_ab=new ArrayBuffer(0);globalThis.zero_ta=new Uint8Array(0);ab.transfer();" ++
        "TypeError.prototype.name='spoofed';globalThis.TypeError=function(){throw new Error('spoofed')};globalThis.ab";
    try evaluate(id, setup, &ab);
    try evaluate(id, "ta", &ta);
    try evaluate(id, "dv", &dv);
    try evaluate(id, "zero_ab", &zero_ab);
    try evaluate(id, "zero_ta", &zero_ta);
    try evaluate(id, "sub", &sub);

    try expectInvalid(ab);
    try expectInvalid(ta);
    try expectInvalid(dv);
    try expectBytes(zero_ab, "");
    try expectBytes(zero_ta, "");
    try expectBytes(sub, &.{ 6, 7 });
}

test "JSC C-created empty ArrayBuffer is attached and copyable" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var zero: u64 = 0;
    defer {
        if (zero != 0) _ = c_api.jsbay_value_release(zero);
    }
    try testing.expectEqual(ok, c_api.jsbay_value_new_array_buffer(id, null, 0, &zero));
    try testing.expect(zero != 0);
    try expectBytes(zero, "");

    var global: u64 = 0;
    defer {
        if (global != 0) _ = c_api.jsbay_value_release(global);
    }
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_engine_global(id, &global));
    try testing.expectEqual(ok, c_api.jsbay_value_set(global, .{ .data = "c_zero".ptr, .len = 6 }, zero, &exception));
    try testing.expectEqual(@as(u64, 0), exception);

    var observed: u64 = 0;
    defer {
        if (observed != 0) _ = c_api.jsbay_value_release(observed);
    }
    try evaluate(id, "c_zero.detached===false&&c_zero.byteLength===0?1:0", &observed);
    var number: f64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_to_number(observed, &number));
    try testing.expectEqual(@as(f64, 1), number);
}

test "JSC copy buffer uses native DataView state without property access" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var shadowed: u64 = 0;
    var zero: u64 = 0;
    var detached: u64 = 0;
    var out_of_bounds: u64 = 0;
    defer {
        for ([_]*u64{ &shadowed, &zero, &detached, &out_of_bounds }) |value| {
            if (value.* != 0) _ = c_api.jsbay_value_release(value.*);
        }
    }
    const setup =
        "globalThis.getterCalls=0;globalThis.backing=new Uint8Array([10,20,30,40]).buffer;" ++
        "globalThis.shadowed=new DataView(backing,1,2);globalThis.zero=new DataView(new ArrayBuffer(0));" ++
        "globalThis.detached=new DataView(new ArrayBuffer(2));detached.buffer.transfer();" ++
        "globalThis.rab=new ArrayBuffer(4,{maxByteLength:8});globalThis.outOfBounds=new DataView(rab,2,2);rab.resize(1);" ++
        "Object.defineProperties(shadowed,{buffer:{get(){getterCalls++;return new ArrayBuffer(2)}}," ++
        "byteOffset:{get(){getterCalls++;return 0}},byteLength:{get(){getterCalls++;return 2}}});" ++
        "globalThis.DataView=function(){throw new Error('replaced')};shadowed";
    try evaluate(id, setup, &shadowed);
    try evaluate(id, "zero", &zero);
    try evaluate(id, "detached", &detached);
    try evaluate(id, "outOfBounds", &out_of_bounds);

    try expectBytes(shadowed, &.{ 20, 30 });
    try expectBytes(zero, "");
    try expectInvalid(detached);
    try expectInvalid(out_of_bounds);

    var calls: u64 = 0;
    defer {
        if (calls != 0) _ = c_api.jsbay_value_release(calls);
    }
    try evaluate(id, "getterCalls", &calls);
    var count: f64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_to_number(calls, &count));
    try testing.expectEqual(@as(f64, 0), count);

    var recovered: u64 = 0;
    defer {
        if (recovered != 0) _ = c_api.jsbay_value_release(recovered);
    }
    try evaluate(id, "40+2", &recovered);
    var number: f64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_to_number(recovered, &number));
    try testing.expectEqual(@as(f64, 42), number);
}
