//! Private module used only by this repository's demos and benchmarks.
//!
//! It deliberately is not re-exported by `src/root.zig`: product consumers use the stable C ABI or the documented Zig surface instead. Keeping these implementation imports here lets repository tools exercise engine internals without making those internals part of the public module.

pub const backend = @import("backend.zig");
pub const dispatch = @import("runtime/dispatch.zig");
pub const engine = @import("engine.zig");
pub const inspector = @import("inspector/root.zig");
pub const jsc_remote_inspector = if (backend.active_backend == .jsc)
    @import("backend/jsc/remote_inspector.zig")
else
    struct {};
pub const promise = @import("runtime/promise.zig");
pub const reference = @import("value/reference.zig");
pub const types = @import("types.zig");
pub const value = @import("value/root.zig");
