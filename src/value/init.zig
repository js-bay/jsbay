//! Comptime value constructor — picks the right `newXxxVal` on the active backend based on the Zig type passed in.

const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

/// Comptime value constructor — dispatches on @typeInfo to create a backend Value. Supports: bool, integers, floats, []const u8, null, and optionals thereof.
pub fn valueInit(ctx: ActiveEngine.Context, val: anytype) ActiveEngine.Value {
    const T = @TypeOf(val);
    const info = @typeInfo(T);

    if (T == @TypeOf(null)) {
        return ActiveEngine.newNullVal(ctx);
    }

    switch (info) {
        .bool => return ActiveEngine.newBoolVal(ctx, val),
        .int, .comptime_int => return ActiveEngine.newInt32Val(ctx, @intCast(val)),
        .float, .comptime_float => return ActiveEngine.newFloat64Val(ctx, @floatCast(val)),
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                return ActiveEngine.newStringVal(ctx, val);
            }
            @compileError("valueInit: unsupported pointer type");
        },
        .optional => {
            if (val) |inner| {
                return valueInit(ctx, inner);
            }
            return ActiveEngine.newNullVal(ctx);
        },
        else => @compileError("valueInit: unsupported type " ++ @typeName(T)),
    }
}
