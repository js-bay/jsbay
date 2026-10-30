//! Backend selection — comptime type alias for the active JS engine.

const build_options = @import("build_options");

pub const BackendType = @TypeOf(build_options.backend);

pub const active_backend = build_options.backend;

/// Whether the engine exposes the QuickJS C-value API used by these shared host capabilities.
pub fn isQuickJsApiBackend(tag: BackendType) bool {
    return tag == .quickjs or tag == .quickjs_ng;
}

/// Apple JavaScriptCore C API backend only (not Escargot/Hermes).
pub fn isJscApiBackend(tag: BackendType) bool {
    return tag == .jsc;
}

pub fn isEscargotBackend(tag: BackendType) bool {
    return tag == .escargot;
}

pub fn isHermesBackend(tag: BackendType) bool {
    return tag == .hermes;
}

/// Pointer-handle value backends that are not QuickJS (JSC, Escargot, Hermes).
pub fn isPointerValueBackend(tag: BackendType) bool {
    return tag == .jsc or tag == .escargot or tag == .hermes;
}

/// Whether this engine exposes the bytecode debugger hooks used by debugger.zig.
pub fn supportsDebugger(tag: BackendType) bool {
    return tag == .quickjs_ng;
}

/// Spike engines: gate advanced features until the native facade is complete.
pub fn isSpikeBackend(tag: BackendType) bool {
    return tag == .escargot or tag == .hermes;
}

pub const ActiveEngine = Engine(active_backend);
pub const ActiveEngineModule = EngineModule(active_backend);

pub fn Engine(comptime tag: BackendType) type {
    return switch (tag) {
        .quickjs => @import("backend/quickjs.zig").QuickJsBackend,
        .quickjs_ng => @import("backend/quickjs_ng.zig").QuickJsNgBackend,
        .jsc => @import("backend/jsc.zig").JscBackend,
        .escargot => @import("backend/escargot.zig").EscargotBackend,
        .hermes => @import("backend/hermes.zig").HermesBackend,
    };
}

pub fn EngineModule(comptime tag: BackendType) type {
    return switch (tag) {
        .quickjs => @import("backend/quickjs.zig"),
        .quickjs_ng => @import("backend/quickjs_ng.zig"),
        .jsc => @import("backend/jsc.zig"),
        .escargot => @import("backend/escargot.zig"),
        .hermes => @import("backend/hermes.zig"),
    };
}
