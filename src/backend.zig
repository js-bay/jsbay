//! Backend selection — comptime type alias for the active JS engine.

const build_options = @import("build_options");

pub const BackendType = @TypeOf(build_options.backend);

pub const active_backend = build_options.backend;

/// Whether the engine exposes the QuickJS C-value API used by these shared host capabilities.
pub fn isQuickJsApiBackend(tag: BackendType) bool {
    return tag == .quickjs or tag == .quickjs_ng;
}

/// Whether this engine exposes the bytecode debugger hooks used by debugger.zig.
pub fn supportsDebugger(tag: BackendType) bool {
    return tag == .quickjs_ng;
}

pub const ActiveEngine = Engine(active_backend);
pub const ActiveEngineModule = EngineModule(active_backend);

pub fn Engine(comptime tag: BackendType) type {
    return switch (tag) {
        .quickjs => @import("backend/quickjs.zig").QuickJsBackend,
        .quickjs_ng => @import("backend/quickjs_ng.zig").QuickJsNgBackend,
        .jsc => @import("backend/jsc.zig").JscBackend,
    };
}

/// Access the raw backend file module (includes file-level declarations like `qjs`, `jsc`, etc.)
pub fn EngineModule(comptime tag: BackendType) type {
    return switch (tag) {
        .quickjs => @import("backend/quickjs.zig"),
        .quickjs_ng => @import("backend/quickjs_ng.zig"),
        .jsc => @import("backend/jsc.zig"),
    };
}
