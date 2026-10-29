//! Timer delay conversion must not trap when JavaScript values are outside the representable range of the native timer API.

const testing = @import("std").testing;
const helpers = @import("test_helpers.zig");

test "JSC timers: clamp large delays and surface Symbol conversion errors" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id,
                \\(() => {
                \\  const fn = () => {};
                \\  const inf = setTimeout(fn, Infinity);
                \\  const huge = setTimeout(fn, Number.MAX_VALUE);
                \\  clearTimeout(inf);
                \\  clearTimeout(huge);
                \\  let setSymbol = false;
                \\  let clearSymbol = false;
                \\  try { setTimeout(fn, Symbol()); } catch (e) { setSymbol = e instanceof TypeError; }
                \\  try { clearTimeout(Symbol()); } catch (e) { clearSymbol = e instanceof TypeError; }
                \\  return `${typeof inf}:${typeof huge}:${setSymbol}:${clearSymbol}`;
                \\})()
            , "number:number:true:true");
        }
    }.run);
}
