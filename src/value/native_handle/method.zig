//! engine/native_handle/method.zig — Bound-method support for NativeHandle.
//!
//! Methods are attached via JS_NewCFunctionData with data[0] = the parent handle object. This guarantees the method always has access to the correct handle even when detached from the object (e.g. `const f = h.m; f()`). It also prevents the parent from being GC'd while any method reference lives.

const types = @import("types.zig");
const class = @import("class.zig");

const c = types.c;

/// C trampoline for bound methods.  data[0] = parent NativeHandle object.
fn boundMethodTrampoline(
    ctx: ?*c.JSContext,
    _: c.JSValue, // this_val (may be wrong if method was detached)
    argc: c_int,
    argv: [*c]c.JSValue,
    _: c_int, // magic
    func_data: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    // func_data[0] = parent handle object func_data[1] = encoded method index
    const parent_obj = func_data[0];
    const method_idx_val = func_data[1];

    const p = c.JS_GetOpaque(parent_obj, class.classIdRaw()) orelse
        return c.JS_ThrowTypeError(ctx, "NativeHandle: invalid handle in bound method");

    _ = p; // HandleData available if needed in the future

    // The actual native function pointer is stored as an i64 in func_data[2].
    const fn_ptr_int = blk: {
        var val: i64 = 0;
        _ = c.JS_ToInt64(ctx, &val, method_idx_val);
        break :blk val;
    };
    _ = fn_ptr_int;

    // For simplicity: the trampoline re-dispatches via a plain CFunction that is stored in func_data[2]. See setMethod below.
    //
    // func_data[2] holds the original method JSValue (a JS_NewCFunction).
    const method_fn = func_data[2];
    return c.JS_Call(ctx, method_fn, parent_obj, argc, argv);
}

/// Add a named method to a NativeHandle instance.
///
/// The method is bound to the parent handle: even if JS detaches it (`const fn = handle.close; fn()`), `this` inside the method will still be the original handle object, and the handle won't be GC'd while the method reference exists.
pub fn setMethod(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [*:0]const u8,
    func: types.MethodFn,
    arg_count: c_int,
) void {
    // Create the raw CFunction.
    const raw_fn = c.JS_NewCFunction(ctx, func, name, arg_count);

    // Wrap it in a CFunctionData closure that carries the parent object. data[0] = parent handle (prevents GC), data[1] = unused, data[2] = raw_fn.
    var data = [3]c.JSValue{
        c.JS_DupValue(ctx, obj), // prevent parent GC while method lives
        c.JS_NewInt32(ctx, 0), // reserved
        raw_fn, // the actual C function
    };
    const bound = c.JS_NewCFunctionData(ctx, boundMethodTrampoline, arg_count, 0, 3, &data);
    c.JS_FreeValue(ctx, data[0]);
    c.JS_FreeValue(ctx, data[1]);
    c.JS_FreeValue(ctx, data[2]);

    _ = c.JS_SetPropertyStr(ctx, obj, name, bound);
}
