//! Runtime / Context lifecycle and `eval` for the JSC backend.
//!
//! Pairs with `common.zig` for the side-table opaque slot and with `value.zig` for value formatting on eval results.

const std = @import("std");
const types = @import("../../types.zig");
const common = @import("common.zig");

const jsc = common.jsc;

pub const Runtime = jsc.JSContextGroupRef;
pub const Context = jsc.JSGlobalContextRef;

pub fn newRuntime() ?Runtime {
    return jsc.JSContextGroupCreate();
}

pub fn setMaxStackSize(_: Runtime, _: usize) void {
    // JSCore does not expose stack size configuration.
}

pub fn newContext(rt: Runtime) ?Context {
    const ctx = jsc.JSGlobalContextCreateInGroup(rt, null);
    if (ctx == null) return null;
    // JSObjectCallAsFunction only accepts an object receiver.  Preserve the pristine Function.prototype.apply before user code can replace globals, so typed calls can still forward primitive/null/undefined `this` values.
    if (!@import("value.zig").captureFunctionApply(ctx)) {
        jsc.JSGlobalContextRelease(ctx);
        return null;
    }
    if (!@import("object_intrinsics.zig").capture(ctx)) {
        @import("value.zig").releaseFunctionApply(ctx);
        jsc.JSGlobalContextRelease(ctx);
        return null;
    }
    return ctx;
}

pub fn freeContext(ctx: Context) void {
    const error_handling = @import("error_handling.zig");
    error_handling.jscPromiseReleaseInstance(@ptrCast(ctx), common.instanceIdFromCtx(ctx));
    @import("object_intrinsics.zig").release(ctx);
    @import("value.zig").releaseFunctionApply(ctx);
    common.removeContextOpaque(ctx);
    jsc.JSGlobalContextRelease(ctx);
}

pub fn freeRuntime(rt: Runtime) void {
    jsc.JSContextGroupRelease(rt);
}

pub fn runGc(_: Runtime) void {
    // JSCore GC is automatic.
}

// ---- Pending jobs ----

pub fn processPendingJobs(ctx: Context) void {
    // JSCore handles promise reactions inside the VM. Deferred finalizers are a separate queue: the GC callback only enqueues, and this turn runs the user function on the engine thread.
    if (ctx == null) return;
    if (!@import("../../runtime/scheduler_gate.zig").allows(@ptrCast(ctx))) return;
    defer @import("../../runtime/scheduler_gate.zig").finished(@ptrCast(ctx));
    @import("../../runtime/engine_thread.zig").runDeferredDrain(common.instanceIdFromCtx(ctx));
}

// ---- Evaluation ----

pub fn eval(ctx: Context, script: []const u8, filename: []const u8) types.EvalResult {
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    const js_script = common.jsStringFromSlice(script) orelse return .{
        .result = null,
        .err = "Out of memory",
        .err_is_heap = false,
    };
    defer jsc.JSStringRelease(js_script);

    const js_url = if (filename.len > 0) common.jsStringFromSlice(filename) orelse return .{
        .result = null,
        .err = "Out of memory",
        .err_is_heap = false,
    } else null;
    defer if (js_url) |u| jsc.JSStringRelease(u);

    var exception: jsc.JSValueRef = null;
    const result = jsc.JSEvaluateScript(jsc_ctx, js_script, null, js_url, 1, &exception);

    if (exception != null) {
        // JavaScriptCore's Error.toString() omits the source URL passed to JSEvaluateScript. Report that filename when the message lacks it, using only the caller-provided length.
        const formatted = common.formatException(jsc_ctx, exception) orelse return .{
            .result = null,
            .err = "JavaScript error",
            .err_is_heap = false,
        };
        if (filename.len == 0 or std.mem.indexOf(u8, formatted, filename) != null) {
            return .{ .result = null, .err = formatted };
        }
        const combined = std.fmt.allocPrint(std.heap.c_allocator, "{s}\n{s}", .{ formatted, filename }) catch {
            return .{ .result = null, .err = formatted };
        };
        std.heap.c_allocator.free(formatted);
        return .{ .result = null, .err = combined };
    }

    if (result == null or jsc.JSValueIsUndefined(jsc_ctx, result) or jsc.JSValueIsNull(jsc_ctx, result)) {
        return .{ .result = null, .err = null };
    } else if (jsc.JSValueIsObject(jsc_ctx, result)) {
        return .{ .result = common.jsonStringify(jsc_ctx, result), .err = null };
    } else {
        return .{ .result = common.valueToString(jsc_ctx, result), .err = null };
    }
}
