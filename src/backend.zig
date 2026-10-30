//! Backend selection — comptime type alias for the active JS engine.

const build_options = @import("build_options");

pub const BackendType = @TypeOf(build_options.backend);

pub const active_backend = build_options.backend;

/// Bitmask of engines linked into this artifact (`-Dbackends=` / single `-Dbackend=`).
pub const packed_backend_bits: u32 = build_options.packed_backend_bits;
pub const multi_pack: bool = build_options.multi_pack;

pub fn isPacked(tag: BackendType) bool {
    const bit: u32 = switch (tag) {
        .quickjs_ng => 1 << 0,
        .quickjs => 1 << 1,
        .jsc => 1 << 2,
    };
    return (packed_backend_bits & bit) != 0;
}

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

/// C ABI `jsbay_backend_t` values (keep in sync with include/jsbay.h).
pub const BackendC = enum(c_int) {
    primary = 0,
    quickjs_ng = 1,
    quickjs = 2,
    jsc = 3,
    _,
};

pub fn libraryBackendC() BackendC {
    return switch (active_backend) {
        .quickjs_ng => .quickjs_ng,
        .quickjs => .quickjs,
        .jsc => .jsc,
    };
}

pub fn backendToC(tag: BackendType) BackendC {
    return switch (tag) {
        .quickjs_ng => .quickjs_ng,
        .quickjs => .quickjs,
        .jsc => .jsc,
    };
}

/// Map a C backend tag to Zig. `primary` (0) resolves to the pack primary.
/// Unknown integers return null.
pub fn backendFromC(raw: c_int) ?BackendType {
    if (raw == @intFromEnum(BackendC.primary)) return active_backend;
    return switch (raw) {
        @intFromEnum(BackendC.quickjs_ng) => .quickjs_ng,
        @intFromEnum(BackendC.quickjs) => .quickjs,
        @intFromEnum(BackendC.jsc) => .jsc,
        else => null,
    };
}

/// Capability bits for `jsbay_engine_capabilities_t.flags` (docs/embedding.md rows + draft §3.2).
pub const CapabilityFlags = struct {
    pub const heap_stack_limit: u32 = 1 << 0;
    pub const heap_usage_snapshot: u32 = 1 << 1;
    pub const interrupt_deadline: u32 = 1 << 2;
    pub const explicit_bytecode: u32 = 1 << 3;
    pub const persistent_bytecode_cache: u32 = 1 << 4;
    pub const cdp_source_debugger: u32 = 1 << 5;
    pub const safari_web_inspector: u32 = 1 << 6;
};

/// Derive capability flags from existing backend predicates / branches — not a parallel myth table.
pub fn libraryCapabilityFlags() u32 {
    var flags: u32 = 0;
    // Interrupt + execution deadline: QJS JS_SetInterruptHandler; JSC private time-limit path.
    flags |= CapabilityFlags.interrupt_deadline;
    if (isQuickJsApiBackend(active_backend)) {
        // setMemoryLimit returns false on JSC; QJS fills MemoryUsage, JSC zeros.
        flags |= CapabilityFlags.heap_stack_limit;
        flags |= CapabilityFlags.heap_usage_snapshot;
        // typed_bytecode.compile/run → unsupported on JSC.
        flags |= CapabilityFlags.explicit_bytecode;
        // cjs.zig: JSC → plainCjs; QJS also requires build_options.bytecode_cache.
        if (build_options.bytecode_cache) {
            flags |= CapabilityFlags.persistent_bytecode_cache;
        }
    }
    if (supportsDebugger(active_backend)) {
        flags |= CapabilityFlags.cdp_source_debugger;
    }
    if (active_backend == .jsc) {
        flags |= CapabilityFlags.safari_web_inspector;
    }
    return flags;
}
