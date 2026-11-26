const backend = @import("../../backend.zig");
const ActiveEngine = backend.ActiveEngine;
const OwnedValue = @import("../../value/reference.zig").OwnedValue;

pub fn throwSpikeException(ctx: ActiveEngine.Context, exception: *OwnedValue) bool {
    if (comptime backend.active_backend == .escargot) {
        const raw = exception.release();
        @import("../../backend/escargot/c_api.zig").escargot_throw_value(ctx, raw);
        return true;
    }
    if (comptime backend.active_backend == .hermes) {
        const api = @import("../../backend/hermes/c_api.zig");
        if (!api.hermes_take_throw_value(ctx, exception.borrow())) return false;
        _ = exception.release();
        return true;
    }
    return false;
}

pub fn throwSpikeTransferFailure(ctx: ActiveEngine.Context) void {
    if (comptime backend.active_backend == .hermes) {
        @import("../../backend/hermes/c_api.zig").hermes_throw_static(ctx, "require: failed to transfer module exception");
    } else {
        _ = ActiveEngine.throwError(ctx, "require: failed to transfer module exception");
    }
}
