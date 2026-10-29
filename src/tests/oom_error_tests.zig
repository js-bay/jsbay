//! Creating an Error must return when the global Error constructor throws or calls back into throwError. The next eval still runs.

const helpers = @import("test_helpers.zig");
const errors = @import("../value/errors.zig");
const value = @import("../value/root.zig");

fn nativeBoom(id: i32, _: value.NativeArgs) value.NativeResult {
    _ = errors.throwError(id, .generic, "from-native");
    return .undefined_val;
}

fn nativeReenter(id: i32, _: value.NativeArgs) value.NativeResult {
    _ = errors.throwError(id, .generic, "reenter");
    return .undefined_val;
}

test "errors: throwError returns when global Error throws" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            value.registerFunction(id, null, "nativeBoom", &nativeBoom);
            try helpers.expectEvalEquals(id,
                \\globalThis.Error = function () { throw "replaced"; };
                \\try { nativeBoom(); } catch (e) {}
                \\String(1+1)
            , "2");
        }
    }.run);
}

test "errors: throwError stops when Error reenters throwError" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            value.registerFunction(id, null, "nativeBoom", &nativeBoom);
            value.registerFunction(id, null, "nativeReenter", &nativeReenter);
            // n is how many times the replacement Error ran. One is the outer construction; a second throwError must not call it again.
            try helpers.expectEvalEquals(id,
                \\globalThis.n = 0;
                \\globalThis.Error = function () {
                \\  globalThis.n++;
                \\  nativeReenter();
                \\  throw "x";
                \\};
                \\try { nativeBoom(); } catch (e) {}
                \\String(globalThis.n)
            , "1");
            try helpers.expectEvalEquals(id, "String(1+1)", "2");
        }
    }.run);
}
