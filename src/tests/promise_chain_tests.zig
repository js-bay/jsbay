//! Promise chain contracts.
//!
//! A throw inside a `then` callback aborts the rest of that callback. If the callback sets a value, throws, then would set another value, only the first write is visible after the microtask drain.

const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");

test "promise: throw inside then skips the rest of the callback" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__v = -1;
                \\new Promise(function (resolve) {
                \\  resolve(0);
                \\}).then(function () {
                \\  globalThis.__v = 0;
                \\  throw error();
                \\  globalThis.__v = 1;
                \\});
            );
            engine.runEventLoopOnce(id);
            try helpers.expectEvalEquals(id, "String(globalThis.__v)", "0");
        }
    }.run);
}
