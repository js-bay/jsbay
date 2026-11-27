const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const api_backend = @import("../abi/api_backend.zig");
const instance_map = @import("instance_map.zig");
const types = @import("../types.zig");
const host_value = @import("../abi/host_value.zig");

const ActiveEngine = backend.ActiveEngine;

pub const status_ok: c_int = 0;
pub const status_timeout: c_int = 1;
pub const status_destroyed: c_int = 2;
pub const status_exception: c_int = 3;
pub const status_invalid: c_int = 4;
pub const status_out_of_memory: c_int = 5;

pub const Adopted = struct {
    status: c_int,
    result: ?[]u8,
    err: ?[]u8,
};

/// The enclosing TypedEvalEntry keeps engine admission active. QuickJS still needs its backend stack anchor for this individual VM entry.
fn serializeThreadValue(ctx: ActiveEngine.Context, value: ActiveEngine.Value) api_backend.BytesResult {
    const entered = if (comptime backend.isQuickJsApiBackend(backend.active_backend))
        backend.ActiveEngineModule.lifecycle.enterJs(ctx)
    else
        true;
    if (!entered) return .out_of_memory;
    defer if (comptime backend.isQuickJsApiBackend(backend.active_backend)) backend.ActiveEngineModule.lifecycle.leaveJs(ctx);
    return api_backend.toUtf8(std.heap.c_allocator, ctx, value);
}

pub fn adoptTypedValue(ctx: ActiveEngine.Context, value: ActiveEngine.Value, status: c_int) Adopted {
    defer ActiveEngine.freeValue(ctx, value);
    const serialized = serializeThreadValue(ctx, value);
    // ToString itself may enqueue microtasks. Drain them before the enclosing admission closes, unless that conversion asked to destroy this runtime.
    if (!instance_map.isTeardownPending(ActiveEngine.instanceIdFromCtx(ctx))) ActiveEngine.processPendingJobs(ctx);
    switch (serialized) {
        .ok => |bytes| return if (status == status_ok)
            .{ .status = status_ok, .result = bytes, .err = null }
        else
            .{ .status = status_exception, .result = null, .err = bytes },
        .exception => |serialization_exception| {
            defer ActiveEngine.freeValue(ctx, serialization_exception);
            const thrown = serializeThreadValue(ctx, serialization_exception);
            if (!instance_map.isTeardownPending(ActiveEngine.instanceIdFromCtx(ctx))) ActiveEngine.processPendingJobs(ctx);
            switch (thrown) {
                .ok => |bytes| return .{ .status = status_exception, .result = null, .err = bytes },
                .exception => |nested| ActiveEngine.freeValue(ctx, nested),
                .out_of_memory => return .{ .status = status_out_of_memory, .result = null, .err = null },
                .invalid_argument => {},
            }
        },
        .out_of_memory => return .{ .status = status_out_of_memory, .result = null, .err = null },
        .invalid_argument => {},
    }
    const fallback = std.heap.c_allocator.dupe(u8, "Unable to serialize JavaScript result") catch
        return .{ .status = status_out_of_memory, .result = null, .err = null };
    return .{ .status = status_exception, .result = null, .err = fallback };
}

pub fn adoptTypedEval(instance_id: i32, result: @import("../script/typed_eval.zig").Result) Adopted {
    if (result.out_of_memory) return .{ .status = status_out_of_memory, .result = null, .err = null };
    const ctx = engine.getContext(instance_id) orelse return .{ .status = status_destroyed, .result = null, .err = null };
    if (result.exception) |exception| return adoptTypedValue(ctx, exception, status_exception);
    if (result.value) |value| return adoptTypedValue(ctx, value, status_ok);
    return .{ .status = status_out_of_memory, .result = null, .err = null };
}

pub fn adoptEval(res: types.EvalResult) Adopted {
    if (res.err) |err_slice| {
        const owned: ?[]u8 = if (res.err_is_heap)
            @constCast(err_slice)
        else
            std.heap.c_allocator.dupe(u8, err_slice) catch null;
        if (res.result) |result_slice| std.heap.c_allocator.free(@constCast(result_slice));
        return .{ .status = status_exception, .result = null, .err = owned };
    }
    if (res.result) |result_slice| {
        return .{
            .status = status_ok,
            .result = @constCast(result_slice),
            .err = null,
        };
    }
    return .{ .status = status_ok, .result = null, .err = null };
}

pub fn writeEval(
    res: types.EvalResult,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    const adopted = adoptEval(res);
    if (adopted.status == status_exception) {
        if (adopted.err) |text| {
            out_error.* = host_value.dupeCString(text);
            std.heap.c_allocator.free(text);
        }
        return status_exception;
    }
    if (adopted.result) |text| {
        out_result.* = host_value.dupeCString(text);
        std.heap.c_allocator.free(text);
    }
    return status_ok;
}
