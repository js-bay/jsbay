//! isConstructor coverage and native receiver / hasReceiver behavior across backends.
//!
//! Bare-call receiver, observed by `thisValue()`: QuickJS: `undefined`. `hasReceiver()` is false (`JS_IsObject`). JSC: the global object. The C callback is sloppy, so `thisObject` is never null and `hasReceiver()` stays true. It is still not the method receiver.

const testing = @import("std").testing;
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

fn dup(s: []const u8) []const u8 {
    return @import("std").heap.c_allocator.dupe(u8, s) catch @panic("oom");
}

fn receiverTag(_: i32, args: value.NativeArgs) value.NativeResult {
    const ctx = engine.getContext(args.instance_id) orelse return .{ .string = dup("no-ctx") };
    const thiz = args.thisValue();
    if (ActiveEngine.isUndefined(ctx, thiz)) return .{ .string = dup("undefined") };
    if (ActiveEngine.isNull(ctx, thiz)) return .{ .string = dup("null") };
    const mark = ActiveEngine.getPropertyVal(ctx, thiz, "mark") orelse return .{ .string = dup("no-mark") };
    defer ActiveEngine.freeValue(ctx, mark);
    const s = ActiveEngine.valueToStringVal(ctx, mark) orelse return .{ .string = dup("bad-mark") };
    return .{ .string = s };
}

fn receiverPresent(_: i32, args: value.NativeArgs) value.NativeResult {
    return .{ .boolean = args.hasReceiver() };
}

fn loadGlobal(id: i32, name: [*:0]const u8) !ActiveEngine.Value {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    return ActiveEngine.getPropertyVal(ctx, global, name) orelse error.Missing;
}

test "isConstructor: class and function(){} are constructors" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            try helpers.evalOk(id, "globalThis.__yes = [class {}, function(){}];");
            const arr = try loadGlobal(id, "__yes");
            defer ActiveEngine.freeValue(ctx, arr);
            for ([_]u32{ 0, 1 }) |index| {
                const item = ActiveEngine.getIndex(ctx, arr, index) orelse return error.Missing;
                defer ActiveEngine.freeValue(ctx, item);
                try testing.expect(value.isConstructor(id, item));
            }
        }
    }.run);
}

test "isConstructor: Math, Reflect, object, generator, async, and arrows are not" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            // Eight non-constructible values, in order.
            try helpers.evalOk(id, "globalThis.__no = [Math, Reflect, {}, function*(){}, async function(){}, async function*(){}, _=>_, async _=>_];");
            const arr = try loadGlobal(id, "__no");
            defer ActiveEngine.freeValue(ctx, arr);
            var index: u32 = 0;
            while (index < 8) : (index += 1) {
                const item = ActiveEngine.getIndex(ctx, arr, index) orelse return error.Missing;
                defer ActiveEngine.freeValue(ctx, item);
                try testing.expect(!value.isConstructor(id, item));
            }

            const num = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, num);
            const undef = ActiveEngine.newUndefinedVal(ctx);
            defer ActiveEngine.freeValue(ctx, undef);
            const nil = ActiveEngine.newNullVal(ctx);
            defer ActiveEngine.freeValue(ctx, nil);
            try testing.expect(!value.isConstructor(id, num));
            try testing.expect(!value.isConstructor(id, undef));
            try testing.expect(!value.isConstructor(id, nil));
        }
    }.run);
}

test "native method call receiver is the object" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            value.registerFunction(id, null, "probe", &receiverTag);
            value.registerFunction(id, null, "probeHas", &receiverPresent);
            try helpers.evalOk(id, "globalThis.mark = 'global'; globalThis.x = { mark: 'obj', probe: probe, probeHas: probeHas };");
            // A method call has the object as receiver.
            try helpers.expectEvalEquals(id, "x.probe()", "obj");
            try helpers.expectEvalEquals(id, "x.probeHas()", "true");
        }
    }.run);
}

test "native bare call receiver is undefined on QuickJS and globalThis on JSC" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            value.registerFunction(id, null, "probe", &receiverTag);
            value.registerFunction(id, null, "probeHas", &receiverPresent);
            try helpers.evalOk(id, "globalThis.mark = 'global'; globalThis.x = { mark: 'obj', probe: probe, probeHas: probeHas };");
            // Not the method object on either backend.
            if (comptime backend.active_backend == .jsc) {
                try helpers.expectEvalEquals(id, "probe()", "global");
                // On JSC, hasReceiver is `thisObject != null`, so a bare call still reports a receiver. Identity is globalThis.
                try helpers.expectEvalEquals(id, "probeHas()", "true");
            } else {
                try helpers.expectEvalEquals(id, "probe()", "undefined");
                try helpers.expectEvalEquals(id, "probeHas()", "false");
            }
        }
    }.run);
}

var retained_receiver: ?ActiveEngine.Value = null;

fn retainReceiver(id: i32, args: value.NativeArgs) value.NativeResult {
    const ctx = engine.getContext(id) orelse return .{ .err = dup("no-ctx") };
    if (retained_receiver) |old| ActiveEngine.freeValue(ctx, old);
    retained_receiver = ActiveEngine.dupValue(ctx, args.thisValue());
    return .undefined_val;
}

// A borrowed value duplicated in the callback must stay valid after the callback returns, the script drops every reference, and the engine collects.
test "native callback can keep its borrowed receiver past the call" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            retained_receiver = null;
            defer if (retained_receiver) |kept| {
                ActiveEngine.freeValue(ctx, kept);
                retained_receiver = null;
            };
            value.registerFunction(id, null, "keep", &retainReceiver);
            try helpers.evalOk(id, "(function () { var holder = { mark: 'kept', pad: [1, 2, 3] }; holder.keep = keep; holder.keep(); })();");
            try helpers.evalOk(id, "for (var i = 0; i < 2000; i++) { globalThis.__junk = { i: i, s: 'x' + i }; } delete globalThis.__junk;");
            engine.runGc(id);
            engine.runGc(id);

            const kept = retained_receiver orelse return error.NotRetained;
            const mark = ActiveEngine.getPropertyVal(ctx, kept, "mark") orelse return error.Missing;
            defer ActiveEngine.freeValue(ctx, mark);
            const text = ActiveEngine.valueToStringVal(ctx, mark) orelse return error.Missing;
            defer value.freeString(text);
            try testing.expectEqualStrings("kept", text);
        }
    }.run);
}
