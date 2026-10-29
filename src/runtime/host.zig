//! Formal host-facing bridge helpers built on top of low-level dispatch.
//!
//! This is the thin stable layer consumers should depend on when they need to call JS entry points from host code. Protocol semantics still belong to the consumer, but the mechanics of binding a context to a named JS handler live here instead of being reassembled ad hoc.

const dispatch = @import("dispatch.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

pub const Arg = dispatch.DispatchArg;

pub const GlobalHandler = struct {
    ctx: ActiveEngine.Context,
    name: [*:0]const u8,

    pub fn callRetained(self: GlobalHandler, args: []const ActiveEngine.Value) ?ActiveEngine.Value {
        return dispatch.callGlobalRetained(self.ctx, self.name, args);
    }

    pub fn call(self: GlobalHandler, args: []const Arg) ?ActiveEngine.Value {
        return dispatch.callGlobalRetainedArgs(self.ctx, self.name, args);
    }

    pub fn emit(self: GlobalHandler, args: []const Arg) bool {
        return dispatch.emitGlobal(self.ctx, self.name, args);
    }

    pub fn emitJson(self: GlobalHandler, json: []const u8) bool {
        return self.emit(&.{.{ .string = json }});
    }
};

pub fn global(ctx: ActiveEngine.Context, name: [*:0]const u8) GlobalHandler {
    return .{
        .ctx = ctx,
        .name = name,
    };
}

const std = @import("std");
const testing = std.testing;

fn withTestContext(comptime test_fn: fn (ActiveEngine.Context, ActiveEngine.Runtime) anyerror!void) !void {
    const rt = ActiveEngine.newRuntime() orelse return error.RuntimeCreationFailed;
    defer ActiveEngine.freeRuntime(rt);

    const ctx = ActiveEngine.newContext(rt) orelse return error.ContextCreationFailed;
    defer ActiveEngine.freeContext(ctx);

    try test_fn(ctx, rt);
}

test "host: global handler emits json payload" {
    try withTestContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const eval_result = ActiveEngine.eval(
                ctx,
                \\globalThis.__host_json__ = (payload) => {
                \\  globalThis.__host_json_value__ = payload;
                \\};
            ,
                "<host-json-test>",
            );
            // ActiveEngine.eval returns owned result/error strings even in module tests.
            defer if (eval_result.result) |s| std.heap.c_allocator.free(@constCast(s));
            defer if (eval_result.err_is_heap) {
                if (eval_result.err) |e| std.heap.c_allocator.free(@constCast(e));
            };
            if (eval_result.err != null) return error.JSException;

            const ok = global(ctx, "__host_json__").emitJson("{\"ok\":true}");
            try testing.expect(ok);

            const read_back = ActiveEngine.eval(ctx, "globalThis.__host_json_value__", "<host-json-read>");
            // Free both success and heap error paths to keep this test ownership-neutral.
            defer if (read_back.result) |s| std.heap.c_allocator.free(@constCast(s));
            defer if (read_back.err_is_heap) {
                if (read_back.err) |e| std.heap.c_allocator.free(@constCast(e));
            };
            if (read_back.err != null) return error.JSException;
            try testing.expectEqualStrings("{\"ok\":true}", read_back.result.?);
        }
    }.run);
}

test "host: missing global handler returns false" {
    try withTestContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try testing.expect(!global(ctx, "__host_missing__").emit(&.{}));
        }
    }.run);
}
