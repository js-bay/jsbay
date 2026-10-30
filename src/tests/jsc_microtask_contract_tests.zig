//! JavaScriptCore's queueMicrotask compatibility surface must keep the web API contract even on hosts that do not provide it natively.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const io = @import("../platform/io.zig");
const helpers = @import("test_helpers.zig");

test "JSC queueMicrotask: returns undefined and rejects non-functions synchronously" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id,
                \\(() => {
                \\  const result = queueMicrotask(() => {});
                \\  let type_errors = true;
                \\  for (const value of [null, undefined, 42]) {
                \\    try { queueMicrotask(value); type_errors = false; }
                \\    catch (error) { type_errors = type_errors && error instanceof TypeError; }
                \\  }
                \\  return `${typeof result}:${type_errors}`;
                \\})()
            , "undefined:true");
        }
    }.run);
}

test "JSC queueMicrotask: reports throws and continues the checkpoint in order" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__jsc_microtask_sequence = '';
                \\globalThis.__jsc_microtask_arg_count = -1;
                \\queueMicrotask(function () {
                \\  globalThis.__jsc_microtask_arg_count = arguments.length;
                \\  globalThis.__jsc_microtask_sequence += 'A';
                \\  throw new Error('jsc queueMicrotask contract throw');
                \\});
                \\queueMicrotask(function () {
                \\  globalThis.__jsc_microtask_sequence += 'B';
                \\  queueMicrotask(function () { globalThis.__jsc_microtask_sequence += 'C'; });
                \\});
                \\setTimeout(function () { globalThis.__jsc_microtask_sequence += 'T'; }, 0);
            );

            var i: u32 = 0;
            while (i < 50) : (i += 1) {
                engine.runEventLoopOnce(id);
                const sequence = try helpers.evalString(testing.allocator, id, "globalThis.__jsc_microtask_sequence");
                const done = std.mem.eql(u8, sequence, "ABCT");
                testing.allocator.free(sequence);
                if (done) break;
                io.sleepMs(1);
            }
            try helpers.expectEvalEquals(id, "globalThis.__jsc_microtask_sequence", "ABCT");
            try helpers.expectEvalEquals(id, "String(globalThis.__jsc_microtask_arg_count)", "0");
        }
    }.run);
}
