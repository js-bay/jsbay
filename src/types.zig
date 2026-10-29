//! Public types shared across the engine. All C ABI types are `extern struct` / `extern enum`.

pub const LogLevel = enum(c_int) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3, // "error" is a Zig keyword
};

/// Result of evaluating a script — either a result string, an error string, or neither. `result` and `err` are heap-allocated via c_allocator when `err_is_heap` is true.
pub const EvalResult = struct {
    result: ?[]const u8 = null,
    err: ?[]const u8 = null,
    /// true if `err` was heap-allocated and must be freed by the caller. false if `err` is a string literal (e.g. "Instance not found").
    err_is_heap: bool = true,
    /// true when `err` came from *decoding* previously-serialized payloads (e.g. stale/corrupt QuickJS bytecode), as opposed to a runtime exception from the script itself. Consumers of persistent caches use this to decide whether a failed replay is worth deleting and rebuilding — a live script that throws must NOT be re-run (double side effects), while undecodable bytes justify a recompile.
    decode_failed: bool = false,
};

/// Log handler callback type. Consumers provide this to receive console.log output.
pub const LogHandler = *const fn (i32, LogLevel, [*:0]const u8, ?*anyopaque) callconv(.c) void;

/// Telemetry event kinds for `EngineEventHandler` (mirrors jsbay_engine_event_kind_t).
pub const EngineEventKind = enum(c_int) {
    log = 0,
    execution_interrupted = 1,
    memory_limit = 2,
    loop_failed = 3,
};

/// Payload delivered to `EngineEventHandler` (mirrors jsbay_engine_event_t).
pub const EngineEvent = extern struct {
    struct_size: u32,
    kind: EngineEventKind,
    instance_id: c_int,
    status: i32 = 0,
    detail: u64 = 0,
    message: ?[*:0]const u8 = null,
};

/// Best-effort host telemetry callback. Must not call engine/Value APIs.
pub const EngineEventHandler = *const fn (*const EngineEvent, ?*anyopaque) callconv(.c) void;

/// Configuration for creating an engine instance.
pub const EngineConfig = struct {
    /// Native timer and asynchronous callback budgets; zero rejects every reservation of that resource.
    resource_limits: @import("runtime/resource_limits.zig").Limits = .{},
    log_handler: ?LogHandler = null,
    /// User data passed to log_handler callbacks.
    log_user_data: ?*anyopaque = null,
    /// Maximum stack size for the JS runtime in bytes. QuickJS: applied to runtime and capped to the executing native thread's available stack. JSC: ignored (not configurable via public API). Default: 1 MiB.
    max_stack_size: usize = 1024 * 1024,
    /// Optional ES module loader vtable. When non-null, top-level `import` statements in sources evaluated through `engine.evalModule` / `engine.importModule` are dispatched here. The pointed-to `ModuleLoader` must outlive the engine instance — the engine does not take ownership.
    ///
    /// QuickJS / QuickJS-NG: `resolve`, `load`, and `free_resolved` are wired through the runtime module callbacks.
    ///
    /// JSC (Apple): `engine.create` installs an ObjC `JSModuleLoaderDelegate` bridge (`src/backend/jsc/module_loader.m`) that invokes `load`. The public JSC API has no separate resolve hook, so `resolve` / `free_resolved` are not called; bare specifiers are rewritten in the bridge and dependencies are fetched by canonical id via `load` only. Requires the private-but-shipping ObjC module symbols (macOS/iOS).
    module_loader: ?*const ModuleLoader = null,
};

/// Result produced by ModuleLoaderVTable.load callback.
///
/// `source` does not need to be NUL-terminated. The backend reads and copies it after the loader callback returns. Return host-owned storage that remains valid while the backend consumes it; do not return stack storage or free the bytes inside the callback.
pub const ModuleLoadResult = extern struct {
    source: [*]const u8,
    source_len: usize,
};

pub const ModuleLoaderVTable = extern struct {
    /// Convert a (referrer, specifier) pair into a canonical absolute id. Return a null pointer to fall back to engine default (use specifier as-is). When returning non-null, the engine calls `free_resolved` (if provided) to release the returned string after copying it into QuickJS-owned memory.
    resolve: ?*const fn (
        user_data: ?*anyopaque,
        referrer: [*:0]const u8,
        specifier: [*:0]const u8,
    ) callconv(.c) ?[*:0]u8 = null,

    /// Load source for a canonical id. Return false to cause a ReferenceError ("could not load module '<id>'") to be thrown into the JS engine. Return true with `out` populated to succeed. The backend consumes `out.source[0..out.source_len]` after this callback returns; loader-owned storage retained for the engine lifetime is suitable.
    load: *const fn (
        user_data: ?*anyopaque,
        canonical_id: [*:0]const u8,
        out: *ModuleLoadResult,
    ) callconv(.c) bool,

    /// Free a string returned by `resolve`. Ignored when `resolve` is null or returned null. Optional: if `free_resolved` is itself null, the engine leaks the returned string (user-owned static buffers are an acceptable design for some hosts).
    free_resolved: ?*const fn (
        user_data: ?*anyopaque,
        ptr: [*:0]u8,
    ) callconv(.c) void = null,
};

/// User-supplied ES module loader passed via EngineConfig.
pub const ModuleLoader = extern struct {
    vtable: *const ModuleLoaderVTable,
    user_data: ?*anyopaque = null,
};
