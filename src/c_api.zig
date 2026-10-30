//! C API export layer for foreign consumers (Swift, JNI, NAPI).
//!
//! The public typed C ABI uses length-delimited UTF-8 and owned Value handles.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const types = @import("types.zig");
const value_mod = @import("value/root.zig");
const backend = @import("backend.zig");
const cache_mod = @import("script/cache.zig");
const runtime_control = @import("runtime/runtime_control.zig");
const engine_thread = @import("runtime/engine_thread.zig");
const inspector_mod = @import("inspector/root.zig");
const api_value = @import("abi/api_value.zig");
const typed_eval = @import("script/typed_eval.zig");
const api_backend = @import("abi/api_backend.zig");
const api_bind = @import("abi/api_bind.zig");
const typed_bytecode = @import("script/typed_bytecode.zig");
const native_sync = @import("js_event_loop").native_sync;
const host_wake = @import("js_event_loop").host_wake;

const ActiveEngine = backend.ActiveEngine;

/// One-shot fault for the next property-key copy shared by set/has/delete.
const key_fault = if (builtin.is_test) struct {
    var fail_next_allocation = false;

    fn request() void {
        fail_next_allocation = true;
    }

    fn consume() bool {
        if (!fail_next_allocation) return false;
        fail_next_allocation = false;
        return true;
    }
} else struct {
    fn consume() bool {
        return false;
    }
};

/// Test-only C-string helpers support Zig regression suites. Production imports receive an empty namespace and only expose the typed execution API.
pub const test_only = if (builtin.is_test) struct {
    pub const advance = testAdvance;
    pub const setWakeHandler = testSetWakeHandler;
    pub const evalCStringUtf8 = testEvalCStringUtf8;
    pub const evalCString = testEvalCString;
    pub const evalCStringBytes = testEvalCStringBytes;
    pub const evalCStringFile = testEvalCStringFile;
    pub const evalCStringCached = testEvalCStringCached;
    pub const freeCString = testFreeCString;
    pub const threadId = testThreadId;
    pub const threadPost = testThreadPost;
    pub const threadWait = testThreadWait;
    pub const threadBarrier = testThreadBarrier;
    pub const threadRun = testThreadRun;
    pub const threadEvalCString = testThreadEvalCString;
    pub const dispatchCString = testDispatchCString;
    pub const failNextKeyAllocation = key_fault.request;
} else struct {};

// QuickJS measures this budget against the native stack pointer, so it must stay below common host thread stack sizes.
const C_API_ENGINE_MAX_STACK_SIZE: usize = 1 * 1024 * 1024;

fn cApiEngineConfig(
    log_handler: ?types.LogHandler,
    log_user_data: ?*anyopaque,
    max_heap_size: usize,
) types.EngineConfig {
    return .{
        .log_handler = log_handler,
        .log_user_data = log_user_data,
        .max_stack_size = C_API_ENGINE_MAX_STACK_SIZE,
        .max_heap_size = max_heap_size,
    };
}

pub const CreateOptions = extern struct {
    struct_size: u32,
    log_handler: ?types.LogHandler = null,
    log_user_data: ?*anyopaque = null,
    max_heap_size: u64 = 0,
};

fn createWithConfig(instance_id: c_int, config: types.EngineConfig) bool {
    if (host_wake.isNotifying()) return false;
    const id: i32 = @intCast(instance_id);
    if (!engine.create(id, config)) return false;
    if (!runtime_control.init(id)) {
        engine.destroy(id);
        return false;
    }
    if (!api_value.noteCreated(id)) {
        engine.destroy(id);
        return false;
    }
    if (config.log_handler) |lh| lh(id, .info, "js_bay create ok", config.log_user_data);
    return true;
}

// ---- Lifecycle ----

pub fn js_bay_engine_create(
    instance_id: c_int,
    log_handler: ?types.LogHandler,
    log_user_data: ?*anyopaque,
) callconv(.c) bool {
    return createWithConfig(instance_id, cApiEngineConfig(log_handler, log_user_data, 0));
}

pub fn js_bay_engine_create2(
    instance_id: c_int,
    opts: ?*const CreateOptions,
) callconv(.c) bool {
    if (opts == null) return js_bay_engine_create(instance_id, null, null);
    const o = opts.?;
    // Require at least through max_heap_size (full CreateOptions as of this ABI revision).
    if (o.struct_size < @sizeOf(CreateOptions)) return false;
    return createWithConfig(
        instance_id,
        cApiEngineConfig(o.log_handler, o.log_user_data, @intCast(o.max_heap_size)),
    );
}

test "c_api: engine creation keeps recursion below native stack limits" {
    // True limitation: recursion-depth probe is QuickJS-stack specific.
    if (comptime backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    try std.testing.expect(js_bay_engine_create(id, null, null));
    defer js_bay_engine_destroy(id);

    var stack_error: ?[*:0]const u8 = null;
    const recursive_result = testEvalCString(
        id,
        "(function recurse(){ return recurse(); })()",
        "<c-api-stack>",
        &stack_error,
    );
    defer if (recursive_result) |result| testFreeCString(result);
    defer if (stack_error) |message| testFreeCString(message);
    try std.testing.expect(recursive_result == null);
    const message = stack_error orelse return error.ExpectedStackOverflow;
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(message), "stack") != null);

    var recovery_error: ?[*:0]const u8 = null;
    const recovery_result = testEvalCString(id, "40+2", "<c-api-recovery>", &recovery_error);
    defer if (recovery_result) |result| testFreeCString(result);
    defer if (recovery_error) |error_message| testFreeCString(error_message);
    try std.testing.expect(recovery_error == null);
    const result = recovery_result orelse return error.ExpectedRecoveryResult;
    try std.testing.expectEqualStrings("42", std.mem.span(result));
}

pub fn js_bay_engine_destroy(instance_id: c_int) callconv(.c) void {
    if (host_wake.isNotifying()) return;
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return;
    // Runtime destruction can be deferred until a host callback unwinds, but foreign hosts may release notification userdata as soon as this returns.
    engine.detachLoop(id);
    host_wake.drop(id);
    // Engine.destroy defers physical teardown while a native callback is on the JS stack. Close the public ABI immediately so its outer operation cannot publish a just-created Value after that callback returns.
    @import("runtime/instance_map.zig").markTeardownPending(id);
    // destroy may be deferred until this callback unwinds, so wake a sync native wait now rather than waiting for engine.destroyNow().
    native_sync.cancelForInstance(id);
    engine.destroy(id);
}

/// Listen for a DevTools connection. `port` 0 picks an ephemeral port. On success, `out_port` receives the bound port when it is non-NULL. A connected client sends Debugger.enable to arm `debugger;` statements. Returns false when the instance is missing or an inspector is already up.
pub export fn js_bay_engine_inspector_start(instance_id: c_int, port: u16, out_port: ?*u16) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    if (engine.getContext(id) == null) return false;
    const handle = inspector_mod.start(id, .{ .port = port }) catch return false;
    if (out_port) |slot| slot.* = inspector_mod.boundPort(handle);
    return true;
}

/// Close the inspector for this instance. Safe if none is running.
pub export fn js_bay_engine_inspector_stop(instance_id: c_int) void {
    if (!api_value.isOwner(@intCast(instance_id))) return;
    inspector_mod.dropInstance(@intCast(instance_id));
}

pub const LoopTask = *const fn (?*anyopaque) callconv(.c) void;
pub const LoopSchedule = *const fn (?*anyopaque, u64, LoopTask, ?*anyopaque) callconv(.c) bool;
pub const LoopCancel = *const fn (?*anyopaque) callconv(.c) void;

pub export fn js_bay_engine_attach_loop(instance_id: c_int, schedule: ?LoopSchedule, cancel: ?LoopCancel, user_data: ?*anyopaque) c_int {
    const id: i32 = @intCast(instance_id);
    if (schedule == null or cancel == null) return API_INVALID_ARGUMENT;
    if (engine.getContext(id) == null or @import("runtime/instance_map.zig").isTeardownPending(id)) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    engine.attachLoop(id, .{ .context = user_data, .schedule = schedule.?, .cancel = cancel.? }) catch |err| {
        if (err == error.ScheduleFailed) {
            @import("runtime/engine_events.zig").fireLoopFailed(id);
            return API_LOOP_FAILED;
        }
        return API_INVALID_ARGUMENT;
    };
    return API_OK;
}

pub export fn js_bay_engine_detach_loop(instance_id: c_int) c_int {
    const id: i32 = @intCast(instance_id);
    if (engine.getContext(id) == null) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    engine.detachLoop(id);
    return API_OK;
}

pub export fn js_bay_engine_loop_status(instance_id: c_int) c_int {
    const id: i32 = @intCast(instance_id);
    const inst = @import("runtime/instance_map.zig").getInstance(id) orelse return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    // LOOP_FAILED events are emitted from attach/run failure paths to avoid per-poll spam.
    return if (inst.loop.lastError() != null) API_LOOP_FAILED else API_OK;
}

pub export fn js_bay_engine_run_loop(instance_id: c_int) c_int {
    const id: i32 = @intCast(instance_id);
    if (engine.getContext(id) == null or @import("runtime/instance_map.zig").isTeardownPending(id)) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    const inst = @import("runtime/instance_map.zig").getInstance(id) orelse return API_INSTANCE_NOT_FOUND;
    if (inst.loop.lastError() != null) return API_LOOP_FAILED;
    if (inst.loop.isAttached()) return API_INVALID_ARGUMENT;
    engine.runEventLoopChecked(id) catch |err| {
        if (err == error.ScheduleFailed) {
            @import("runtime/engine_events.zig").fireLoopFailed(id);
            return API_LOOP_FAILED;
        }
        return API_INVALID_ARGUMENT;
    };
    return API_OK;
}

pub export fn js_bay_engine_stop_loop(instance_id: c_int) bool {
    return @import("runtime/instance_map.zig").withInstanceReturn(@as(i32, @intCast(instance_id)), struct {
        pub fn call(_: @This(), inst: *@import("runtime/instance_map.zig").EngineInstance) ?bool {
            inst.loop.requestStop();
            return true;
        }
    }{}) orelse false;
}

fn testSetWakeHandler(instance_id: c_int, handler: ?host_wake.Handler, user_data: ?*anyopaque) c_int {
    if (host_wake.isNotifying()) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    if (@import("runtime/instance_map.zig").isTeardownPending(id) or engine.getContext(id) == null) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    host_wake.set(id, handler, user_data) catch return API_OUT_OF_MEMORY;
    return API_OK;
}

/// Thread-safe control-plane request. The engine owner observes the flag from its backend interrupt handler and turns the running evaluation into an exception; this function never waits for the JavaScript thread.
pub fn js_bay_engine_request_interrupt(instance_id: c_int) callconv(.c) bool {
    const id: i32 = @intCast(instance_id);
    const accepted = runtime_control.requestInterrupt(id);
    if (accepted) {
        native_sync.cancelForInstance(id);
        @import("runtime/engine_events.zig").fireInterrupted(id, 0, "interrupt requested");
    }
    return accepted;
}

/// Clear a previously requested interrupt before evaluating more JavaScript.
pub fn js_bay_engine_clear_interrupt(instance_id: c_int) callconv(.c) bool {
    if (!api_value.isOwner(@intCast(instance_id))) return false;
    return runtime_control.clearInterrupt(@intCast(instance_id));
}

/// Arm a relative execution limit without blocking the caller. Zero disables the limit. The backend interrupt handler owns enforcement.
pub fn js_bay_engine_set_execution_time_limit(instance_id: c_int, millis: u64) callconv(.c) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    const accepted = runtime_control.setExecutionTimeLimit(id, millis);
    if (accepted) if (runtime_control.executionDeadlineMillis(id)) |deadline| {
        native_sync.tightenDeadlinesForInstance(id, deadline);
    };
    return accepted;
}

/// Cap the runtime's heap at `bytes` (0 = unlimited). QuickJS enforces it via JS_SetMemoryLimit. JSC has no public heap-cap API and returns false (same contract as `runtime_control.setMemoryLimit` / the C header).
pub fn js_bay_engine_set_memory_limit(instance_id: c_int, bytes: u64) callconv(.c) bool {
    if (!api_value.isOwner(@intCast(instance_id))) return false;
    return runtime_control.setMemoryLimit(@intCast(instance_id), bytes);
}

/// Owner-thread memory snapshot. Fills zeros first; false when missing, wrong thread, or null out.
pub const MemoryUsageC = extern struct {
    struct_size: u32,
    malloc_count: u64 = 0,
    malloc_size: u64 = 0,
    malloc_limit: u64 = 0,
    memory_used_count: u64 = 0,
    memory_used_size: u64 = 0,
    atom_count: u64 = 0,
    atom_size: u64 = 0,
    obj_count: u64 = 0,
    obj_size: u64 = 0,
    shape_count: u64 = 0,
};

pub fn js_bay_engine_get_memory_usage(instance_id: c_int, out_usage: ?*MemoryUsageC) callconv(.c) bool {
    const out = out_usage orelse return false;
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    const caller_size = out.struct_size;
    if (caller_size < 4) return false;
    const snap = runtime_control.getMemoryUsage(id) orelse return false;
    var filled = MemoryUsageC{
        .struct_size = caller_size,
        .malloc_count = snap.malloc_count,
        .malloc_size = snap.malloc_size,
        .malloc_limit = snap.malloc_limit,
        .memory_used_count = snap.memory_used_count,
        .memory_used_size = snap.memory_used_size,
        .atom_count = snap.atom_count,
        .atom_size = snap.atom_size,
        .obj_count = snap.obj_count,
        .obj_size = snap.obj_size,
        .shape_count = snap.shape_count,
    };
    const copy_len = @min(caller_size, @sizeOf(MemoryUsageC));
    const src: [*]const u8 = @ptrCast(&filled);
    const dst: [*]u8 = @ptrCast(out);
    @memset(dst[0..caller_size], 0);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    out.struct_size = caller_size;
    return true;
}

/// Owner-thread forced GC. Returns false when missing or wrong thread.
pub fn js_bay_engine_run_gc(instance_id: c_int) callconv(.c) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    return runtime_control.runGc(id);
}

const engine_events = @import("runtime/engine_events.zig");

/// Owner-thread telemetry handler registration. Pass null handler to clear.
pub fn js_bay_engine_set_event_handler(
    instance_id: c_int,
    handler: ?types.EngineEventHandler,
    user_data: ?*anyopaque,
) callconv(.c) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    if (@import("runtime/instance_map.zig").getInstance(id) == null) return false;
    return engine_events.setHandler(id, handler, user_data);
}

fn maybeFireInterrupted(id: i32) void {
    if (runtime_control.isInterruptRequested(id)) {
        engine_events.fireInterrupted(id, 0, "interrupt requested");
        return;
    }
    if (runtime_control.remainingExecutionLimitMillis(id)) |remaining| {
        if (remaining == 0) engine_events.fireInterrupted(id, 0, "execution time limit");
    }
}

fn maybeFireMemoryLimit(id: i32, status: c_int) void {
    const usage = runtime_control.getMemoryUsage(id) orelse return;
    if (usage.malloc_limit == 0) return;
    engine_events.fireMemoryLimit(id, usage.malloc_limit, @intCast(status));
}

// ---- Evaluation ----

/// Copy an `EvalResult` into the malloc'd C-string contract used by `testEvalCString`. The caller frees both strings with `testFreeCString`.
fn publishEvalResult(result: types.EvalResult, out_error: ?*?[*:0]const u8) ?[*:0]const u8 {
    if (out_error) |ep| ep.* = null;
    if (result.err) |err_slice| {
        if (out_error) |ep| {
            ep.* = sliceToCString(err_slice);
        }
        if (result.err_is_heap) {
            std.heap.c_allocator.free(@constCast(err_slice));
        }
        return null;
    }

    if (result.result) |res_slice| {
        const cstr = sliceToCString(res_slice);
        std.heap.c_allocator.free(@constCast(res_slice));
        return cstr;
    }

    return null;
}

fn publishCachedEvalResult(result: cache_mod.CachedEvalResult, out_error: ?*?[*:0]const u8) ?[*:0]const u8 {
    return publishEvalResult(.{ .result = result.result, .err = result.err, .err_is_heap = result.err_is_heap }, out_error);
}

fn scriptBytes(script: [*]const u8, script_len: usize) []const u8 {
    if (script_len == 0) return "";
    return script[0..script_len];
}

pub const Utf8 = extern struct {
    data: ?[*]const u8,
    len: usize,
};
pub const Bytes = extern struct {
    data: ?[*]u8,
    len: usize,
};

pub const EvalOptions = extern struct {
    struct_size: u32,
    cache_dir: Utf8,
    cache_version: Utf8,
    out_cache_hit: ?*bool,
};

fn checkedUtf8(value: Utf8) ?[]const u8 {
    if (value.data) |data| return data[0..value.len];
    return if (value.len == 0) "" else null;
}

fn invalidEvalArguments(out_error: ?*?[*:0]const u8, message: []const u8) ?[*:0]const u8 {
    if (out_error) |slot| slot.* = sliceToCString(message);
    return null;
}

/// The canonical C evaluation entry point. `options` is optional; when it enables caching, cache directory and cache version must be supplied together.
fn testEvalCStringUtf8(
    instance_id: c_int,
    source_arg: Utf8,
    filename_arg: Utf8,
    options: ?*const EvalOptions,
    out_error: ?*?[*:0]const u8,
) ?[*:0]const u8 {
    if (out_error) |slot| slot.* = null;
    const source = checkedUtf8(source_arg) orelse return invalidEvalArguments(out_error, "source.data is null with non-zero length");
    const filename = checkedUtf8(filename_arg) orelse return invalidEvalArguments(out_error, "filename.data is null with non-zero length");

    if (options) |opts| {
        if (opts.out_cache_hit) |hit| hit.* = false;
        if (opts.struct_size < @sizeOf(EvalOptions)) return invalidEvalArguments(out_error, "eval options struct_size is too small");
        const cache_dir = checkedUtf8(opts.cache_dir) orelse return invalidEvalArguments(out_error, "cache_dir.data is null with non-zero length");
        const cache_version = checkedUtf8(opts.cache_version) orelse return invalidEvalArguments(out_error, "cache_version.data is null with non-zero length");
        const cache_enabled = cache_dir.len != 0 or cache_version.len != 0;
        if (cache_enabled and (cache_dir.len == 0 or cache_version.len == 0)) return invalidEvalArguments(out_error, "cache_dir and cache_version must both be non-empty");
        if (cache_enabled) {
            const result = cache_mod.evalCached(@intCast(instance_id), source, filename, cache_dir, cache_version);
            if (opts.out_cache_hit) |hit| hit.* = result.cache_hit;
            return publishCachedEvalResult(result, out_error);
        }
    }
    return publishEvalResult(engine.evalScript(@intCast(instance_id), source, filename), out_error);
}

/// Evaluate a script and return the result as a null-terminated C string. On success: returns the result string (caller must free with `testFreeCString`). On error: returns null and writes the error message to `out_error` (also must be freed). If both result and error are null, the script returned undefined/void.
fn testEvalCString(
    instance_id: c_int,
    script: [*:0]const u8,
    filename: [*:0]const u8,
    out_error: ?*?[*:0]const u8,
) callconv(.c) ?[*:0]const u8 {
    return testEvalCStringUtf8(instance_id, .{ .data = script, .len = std.mem.len(script) }, .{ .data = filename, .len = std.mem.len(filename) }, null, out_error);
}

/// Evaluate a pointer+length script buffer. `script` need not be NUL-terminated; only `script_len` bytes are the program. `filename` is a display name. Result contract matches `testEvalCString` (free with `testFreeCString`).
fn testEvalCStringBytes(
    instance_id: c_int,
    script: [*]const u8,
    script_len: usize,
    filename: [*:0]const u8,
    out_error: ?*?[*:0]const u8,
) ?[*:0]const u8 {
    return testEvalCStringUtf8(instance_id, .{ .data = script, .len = script_len }, .{ .data = filename, .len = std.mem.len(filename) }, null, out_error);
}

/// Evaluate the script stored at a filesystem path via `engine.evalFile`. Result contract matches `testEvalCString` (free with `testFreeCString`).
fn testEvalCStringFile(
    instance_id: c_int,
    path: [*:0]const u8,
    out_error: ?*?[*:0]const u8,
) ?[*:0]const u8 {
    const result = engine.evalFile(@intCast(instance_id), std.mem.span(path));
    return publishEvalResult(result, out_error);
}

/// Evaluate `script` (a named engine-level script such as an asset bundle) via the engine-side bytecode cache at `cache_dir`.
///
/// Compiles once, persists `<version>-<sha256(script)>.bc` under `cache_dir`, and replays the bytes on later calls — skipping re-parse. Deterministic (named) scripts only: content-addressed, so anything with per-call-variant content would never hit and only bloat the dir.
///
/// On any cache/compile failure it degrades to a plain eval, so enabling this can never break cold start. `out_cache_hit` reports whether the cached variant ran (for telemetry); `out_error` carries the eval error message, same contract as `testEvalCString`.
fn testEvalCStringCached(
    instance_id: c_int,
    script: [*]const u8,
    script_len: usize,
    filename: [*:0]const u8,
    cache_dir: [*]const u8,
    cache_dir_len: usize,
    version: [*]const u8,
    version_len: usize,
    out_error: ?*?[*:0]const u8,
    out_cache_hit: ?*bool,
) callconv(.c) ?[*:0]const u8 {
    var options = EvalOptions{ .struct_size = @sizeOf(EvalOptions), .cache_dir = .{ .data = cache_dir, .len = cache_dir_len }, .cache_version = .{ .data = version, .len = version_len }, .out_cache_hit = out_cache_hit };
    return testEvalCStringUtf8(instance_id, .{ .data = script, .len = script_len }, .{ .data = filename, .len = std.mem.len(filename) }, &options, out_error);
}

// ---- Memory ----

/// Free a string returned by `testEvalCString`, `testEvalCStringBytes`, or `testEvalCStringFile`.
fn testFreeCString(s: ?[*:0]const u8) callconv(.c) void {
    if (s) |ptr| {
        // Recover the full sentinel-terminated slice from the pointer
        const slice = std.mem.span(ptr);
        // Free the allocation (len + 1 for sentinel)
        std.heap.c_allocator.free(@constCast(slice[0 .. slice.len + 1]));
    }
}

fn testAdvance(instance_id: c_int, now_ms: i64) i64 {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return -1;
    return engine.testing.advance(id, now_ms);
}

const API_OK: c_int = 0;
const API_EXCEPTION: c_int = 1;
const API_INVALID_ARGUMENT: c_int = 2;
const API_WRONG_THREAD: c_int = 3;
const API_INSTANCE_NOT_FOUND: c_int = 4;
const API_STALE_VALUE: c_int = 5;
const API_OUT_OF_MEMORY: c_int = 6;
const API_UNSUPPORTED: c_int = 7;
const API_LOOP_FAILED: c_int = 8;

const ApiOp = struct {
    id: i32,
    ctx: ActiveEngine.Context,
    lease: engine_thread.EvalLease,
    entered_js: bool,
    execution: ?@import("js_event_loop").Scheduler.Execution = null,

    fn endExecution(self: *ApiOp) void {
        if (self.execution) |*guard| guard.end();
        self.execution = null;
    }

    fn deinit(self: *ApiOp) void {
        if (self.execution != null) {
            self.endExecution();
            @import("runtime/js_scheduler.zig").checkpoint(self.id, self.ctx);
        }
        // Raw typed operations below use backend C APIs directly.  Keep the QuickJS stack anchor around the entire admission lease, including re-entrant getter/toString/native-callback execution.
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            if (self.entered_js) backend.ActiveEngineModule.lifecycle.leaveJs(self.ctx);
        }
        engine.finishEvalEntry(self.id, self.lease);
    }
};

fn beginApiOp(id: i32) union(enum) { ok: ApiOp, status: c_int } {
    if (host_wake.isNotifying()) return .{ .status = API_INVALID_ARGUMENT };
    if (@import("runtime/instance_map.zig").isTeardownPending(id)) return .{ .status = API_INSTANCE_NOT_FOUND };
    if (!api_value.isOwner(id)) return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    if (@import("runtime/instance_map.zig").getInstance(id)) |inst| {
        if (inst.loop.lastError() != null) return .{ .status = API_LOOP_FAILED };
    }
    const lease = engine_thread.beginEval(id);
    if (!lease.allowed) return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    const ctx = engine.getContext(id) orelse {
        engine.finishEvalEntry(id, lease);
        return .{ .status = API_INSTANCE_NOT_FOUND };
    };
    const entered_js = if (comptime backend.isQuickJsApiBackend(backend.active_backend)) backend.ActiveEngineModule.lifecycle.enterJs(ctx) else true;
    if (!entered_js) {
        engine.finishEvalEntry(id, lease);
        return .{ .status = API_WRONG_THREAD };
    }
    return .{ .ok = .{ .id = id, .ctx = ctx, .lease = lease, .entered_js = entered_js, .execution = @import("runtime/js_scheduler.zig").beginExecution(id) } };
}

fn apiContext(instance_id: i32) union(enum) { ok: ActiveEngine.Context, status: c_int } {
    const ptrs = @import("runtime/instance_map.zig").getPtrs(instance_id) orelse return .{ .status = API_INSTANCE_NOT_FOUND };
    if (!api_value.isOwner(instance_id)) return .{ .status = API_WRONG_THREAD };
    return .{ .ok = ptrs.ctx };
}

/// Resolve a public handle while keeping the runtime admitted for the whole operation.  A handle lookup alone is not sufficient: a callback may ask to destroy its engine and otherwise leave the remainder of this API call with a freed context.
const ValueOp = struct {
    op: ApiOp,
    value: ActiveEngine.Value,

    fn deinit(self: *ValueOp) void {
        ActiveEngine.freeValue(self.op.ctx, self.value);
        self.op.deinit();
    }
};

fn beginValueOp(handle: u64) union(enum) { ok: ValueOp, status: c_int } {
    const entry = api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
    var op = switch (beginApiOp(entry.instance_id)) {
        .status => |status| return .{ .status = status },
        .ok => |value| value,
    };
    // Re-read while admitted, then pin a backend reference. A getter/toString can re-enter the C ABI and release the public handle being operated on.
    const live = api_value.get(handle) orelse {
        op.deinit();
        return .{ .status = API_STALE_VALUE };
    };
    if (live.instance_id != op.id) {
        op.deinit();
        return .{ .status = API_STALE_VALUE };
    }
    return .{ .ok = .{ .op = op, .value = ActiveEngine.dupValue(op.ctx, live.value) } };
}

fn pinValue(op: ApiOp, handle: u64) union(enum) { ok: ActiveEngine.Value, status: c_int } {
    const entry = api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
    if (entry.instance_id != op.id) return .{ .status = API_STALE_VALUE };
    return .{ .ok = ActiveEngine.dupValue(op.ctx, entry.value) };
}

fn apiStore(instance_id: i32, value: ActiveEngine.Value, out: *u64) c_int {
    out.* = 0;
    // A getter/native callback may request destroy while raw backend work is re-entered. Never publish a value that is invalid as soon as this C call returns; retain the backend ownership only long enough to release it.
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) {
        if (@import("runtime/instance_map.zig").getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, value);
        return API_INSTANCE_NOT_FOUND;
    }
    out.* = api_value.putOwned(instance_id, value) orelse {
        if (@import("runtime/instance_map.zig").getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, value);
        return API_OUT_OF_MEMORY;
    };
    return API_OK;
}

fn drainApiJobs(op: *ApiOp) bool {
    op.endExecution();
    const map = @import("runtime/instance_map.zig");
    if (!map.isTeardownPending(op.id)) @import("runtime/js_scheduler.zig").checkpoint(op.id, op.ctx);
    return !map.isTeardownPending(op.id);
}

fn discardBackendResult(ctx: ActiveEngine.Context, result: api_backend.Result) void {
    if (result.value) |value| ActiveEngine.freeValue(ctx, value);
    if (result.exception) |exception| ActiveEngine.freeValue(ctx, exception);
}

fn discardBytesResult(ctx: ActiveEngine.Context, result: api_backend.BytesResult) void {
    if (result.bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (result.exception) |exception| ActiveEngine.freeValue(ctx, exception);
}

fn discardTypedBytecodeResult(ctx: ActiveEngine.Context, result: typed_bytecode.Result) void {
    if (result.bytes) |bytes| typed_bytecode.freeBytes(bytes);
    if (result.value) |value| ActiveEngine.freeValue(ctx, value);
    if (result.exception) |exception| ActiveEngine.freeValue(ctx, exception);
}

pub export fn js_bay_value_retain(value: u64, out_value: *u64) c_int {
    out_value.* = 0;
    const instance_id = api_value.instanceFor(value) orelse return API_STALE_VALUE;
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    out_value.* = api_value.retain(value) orelse return API_OUT_OF_MEMORY;
    return API_OK;
}

pub export fn js_bay_value_release(value: u64) c_int {
    const instance_id = api_value.instanceFor(value) orelse return API_STALE_VALUE;
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return if (api_value.release(value)) API_OK else API_STALE_VALUE;
}

pub export fn js_bay_engine_global(instance_id_raw: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const instance_id: i32 = @intCast(instance_id_raw);
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(instance_id, ActiveEngine.getGlobalObject(op.ctx), out_value);
}

fn apiNewSimple(instance_id_raw: c_int, out_value: *u64, comptime make: anytype) c_int {
    out_value.* = 0;
    const instance_id: i32 = @intCast(instance_id_raw);
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(instance_id, make(op.ctx), out_value);
}

pub export fn js_bay_value_undefined(instance_id: c_int, out_value: *u64) c_int {
    return apiNewSimple(instance_id, out_value, struct {
        fn make(_: ActiveEngine.Context) ActiveEngine.Value {
            return ActiveEngine.undefinedValue();
        }
    }.make);
}

pub export fn js_bay_value_null(instance_id: c_int, out_value: *u64) c_int {
    return apiNewSimple(instance_id, out_value, struct {
        fn make(_: ActiveEngine.Context) ActiveEngine.Value {
            return ActiveEngine.nullValue();
        }
    }.make);
}

pub export fn js_bay_value_new_bool(instance_id: c_int, input: bool, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(id, ActiveEngine.newBoolVal(op.ctx, input), out_value);
}

pub export fn js_bay_value_new_number(instance_id: c_int, input: f64, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(id, ActiveEngine.newFloat64Val(op.ctx, input), out_value);
}

pub export fn js_bay_value_new_string(instance_id: c_int, input: Utf8, out_value: *u64) c_int {
    out_value.* = 0;
    const bytes = checkedUtf8(input) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(bytes)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newString(op.ctx, bytes);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

pub export fn js_bay_value_new_array_buffer(instance_id: c_int, data: ?[*]const u8, len: usize, out_value: *u64) c_int {
    out_value.* = 0;
    const bytes: []const u8 = if (data) |ptr| ptr[0..len] else if (len == 0) "" else return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newArrayBuffer(op.ctx, bytes);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

pub export fn js_bay_value_type(value: u64, out_kind: *c_int) c_int {
    out_kind.* = 0;
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    out_kind.* = if (ActiveEngine.isUndefined(data.op.ctx, data.value)) 0 else if (ActiveEngine.isNull(data.op.ctx, data.value)) 1 else if (ActiveEngine.isBool(data.op.ctx, data.value)) 2 else if (ActiveEngine.isNumber(data.op.ctx, data.value)) 3 else if (ActiveEngine.isString(data.op.ctx, data.value)) 4 else if (ActiveEngine.isArray(data.op.ctx, data.value)) 6 else if (ActiveEngine.isFunction(data.op.ctx, data.value)) 7 else if (ActiveEngine.isSymbol(data.op.ctx, data.value)) 8 else if (ActiveEngine.isBigInt(data.op.ctx, data.value)) 9 else 5;
    return API_OK;
}

pub export fn js_bay_value_to_bool(value: u64, out_value: *bool) c_int {
    out_value.* = false;
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    if (!ActiveEngine.isBool(data.op.ctx, data.value)) return API_INVALID_ARGUMENT;
    out_value.* = ActiveEngine.toBool(data.op.ctx, data.value) orelse return API_INVALID_ARGUMENT;
    return API_OK;
}

pub export fn js_bay_value_to_number(value: u64, out_value: *f64) c_int {
    out_value.* = 0;
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    if (!ActiveEngine.isNumber(data.op.ctx, data.value)) return API_INVALID_ARGUMENT;
    out_value.* = ActiveEngine.toFloat64(data.op.ctx, data.value) orelse return API_INVALID_ARGUMENT;
    return API_OK;
}

pub export fn js_bay_value_new_object(instance_id: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newObject(op.ctx);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

pub export fn js_bay_value_new_array(instance_id: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newArray(op.ctx, 0);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

// The remaining Value operations are exported here while their backend-typed exception paths are being shared by all three engines. They clear every output before reporting unsupported so FFI callers never observe stale data.
fn noEmbeddedNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null;
}

fn duplicateKey(key: []const u8) ?[:0]u8 {
    if (key_fault.consume()) return null;
    return std.heap.c_allocator.dupeSentinel(u8, key, 0) catch null;
}

pub export fn js_bay_engine_evaluate(instance_id_raw: c_int, source_arg: Utf8, filename_arg: Utf8, options: ?*const EvalOptions, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const source = checkedUtf8(source_arg) orelse return API_INVALID_ARGUMENT;
    const filename = checkedUtf8(filename_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(filename) or !noEmbeddedNul(filename)) return API_INVALID_ARGUMENT;
    var cache_dir: []const u8 = "";
    var cache_version: []const u8 = "";
    if (options) |opts| {
        if (opts.struct_size < @sizeOf(EvalOptions)) return API_INVALID_ARGUMENT;
        if (opts.out_cache_hit) |hit| hit.* = false;
        cache_dir = checkedUtf8(opts.cache_dir) orelse return API_INVALID_ARGUMENT;
        cache_version = checkedUtf8(opts.cache_version) orelse return API_INVALID_ARGUMENT;
        if (!noEmbeddedNul(cache_dir) or !noEmbeddedNul(cache_version)) return API_INVALID_ARGUMENT;
        if ((cache_dir.len == 0) != (cache_version.len == 0)) return API_INVALID_ARGUMENT;
    }
    const id: i32 = @intCast(instance_id_raw);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |value| value,
    };
    defer op.deinit();
    var execution = @import("runtime/js_scheduler.zig").beginExecution(id) orelse return API_INSTANCE_NOT_FOUND;
    @import("inspector/debugger.zig").noteScript(id, filename, source);
    @import("inspector/debugger.zig").clearExceptionHold(id);
    const result = typed_eval.evaluate(op.ctx, source, filename, cache_dir, cache_version);
    execution.end();
    if (!drainApiJobs(&op)) {
        if (result.value) |value| ActiveEngine.freeValue(op.ctx, value);
        if (result.exception) |exception| ActiveEngine.freeValue(op.ctx, exception);
        return API_INSTANCE_NOT_FOUND;
    }
    if (options) |opts| {
        if (opts.out_cache_hit) |hit| hit.* = result.cache_hit;
    }
    if (result.out_of_memory) {
        maybeFireMemoryLimit(id, API_OUT_OF_MEMORY);
        return API_OUT_OF_MEMORY;
    }
    if (result.exception) |exception| {
        // Time-limit / requestInterrupt both surface as JS exceptions; memory-limit OOM may also.
        maybeFireInterrupted(id);
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    if (result.value) |value| return apiStore(id, value, out_value);
    maybeFireMemoryLimit(id, API_OUT_OF_MEMORY);
    return API_OUT_OF_MEMORY;
}
test "c_api: evaluation and cache preserve inspector source contract" {
    if (comptime backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const testing = std.testing;
    const debugger = @import("inspector/debugger.zig");
    const instance_map = @import("runtime/instance_map.zig");
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    try testing.expect(js_bay_engine_create(id, null, null));
    defer js_bay_engine_destroy(id);
    const instance = instance_map.getInstance(id) orelse return error.MissingEngine;
    const inspector_enabled = @import("build_options").inspector;
    if (comptime inspector_enabled) {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return error.SkipZigTest;
        try testing.expect(debugger.attach(id, @ptrCast(@constCast(instance.runtime))));
    } else {
        try testing.expect(!debugger.attach(id, @ptrCast(@constCast(instance.runtime))));
    }
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory);
    const source = "globalThis.apiDebugRuns=(globalThis.apiDebugRuns||0)+1;apiDebugRuns";
    const filename = "c-api-inspector-source.js";
    var hit = false;
    var options = EvalOptions{
        .struct_size = @sizeOf(EvalOptions),
        .cache_dir = .{ .data = directory.ptr, .len = directory.len },
        .cache_version = .{ .data = "v1", .len = 2 },
        .out_cache_hit = &hit,
    };
    try testing.expectEqual(@as(u32, 0), debugger.scriptIdForUrl(id, filename));
    for (0..3) |index| {
        var value: u64 = 0;
        var exception: u64 = 0;
        hit = false;
        try testing.expectEqual(API_OK, js_bay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, if (index < 2) &options else null, &value, &exception));
        defer _ = js_bay_value_release(value);
        try testing.expectEqual(@as(u64, 0), exception);
        try testing.expectEqual(@import("build_options").bytecode_cache and !backend.isJscApiBackend(backend.active_backend) and index == 1, hit);
        const script_id = debugger.scriptIdForUrl(id, filename);
        if (comptime inspector_enabled) {
            try testing.expect(script_id != 0);
            const script = debugger.scriptById(id, script_id) orelse return error.MissingDebuggerSource;
            defer debugger.freeScriptInfo(script);
            try testing.expectEqualStrings(source, script.source);
            try testing.expectEqualStrings(filename, script.url);
        } else {
            try testing.expectEqual(@as(u32, 0), script_id);
        }
        var runs: f64 = 0;
        try testing.expectEqual(API_OK, js_bay_value_to_number(value, &runs));
        try testing.expectEqual(@as(f64, @floatFromInt(index + 1)), runs);
    }
}

pub export fn js_bay_value_new_json(instance_id_raw: c_int, input_arg: Utf8, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const input = checkedUtf8(input_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(input)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id_raw);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |value| value,
    };
    defer op.deinit();
    const result = api_backend.parseJson(op.ctx, input);
    if (!drainApiJobs(&op)) {
        discardBackendResult(op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn js_bay_value_new_error(instance_id_raw: c_int, message_arg: Utf8, out_value: *u64) c_int {
    out_value.* = 0;
    const message = checkedUtf8(message_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(message)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id_raw);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |value| value,
    };
    defer op.deinit();
    const result = api_backend.newError(op.ctx, message);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        // Constructors report an internal failure as a non-exception status; no out_exception exists on this API surface.
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn js_bay_value_to_utf8(value: u64, out_bytes: *Bytes, out_exception: *u64) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.toUtf8(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBytesResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    // QuickJS exposes unpaired UTF-16 surrogates as WTF-8. The public ABI promises ordinary UTF-8, so rewrite each surrogate half to U+FFFD in place. Valid UTF-8 (including NUL and paired emoji) is untouched.
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        std.unicode.wtf8ToUtf8Lossy(bytes, bytes) catch {
            std.heap.c_allocator.free(bytes);
            return API_INVALID_ARGUMENT;
        };
    }
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}
pub export fn js_bay_value_to_json(value: u64, out_bytes: *Bytes, out_exception: *u64) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.toJson(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBytesResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}
pub export fn js_bay_value_copy_buffer(value: u64, out_bytes: *Bytes, out_exception: *u64) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.copyBuffer(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBytesResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}
pub export fn js_bay_free_bytes(bytes: Bytes) void {
    if (bytes.data) |data| std.heap.c_allocator.free(data[0..bytes.len]);
}
pub export fn js_bay_value_get(object: u64, key_arg: Utf8, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const key = checkedUtf8(key_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(key) or !noEmbeddedNul(key)) return API_INVALID_ARGUMENT;
    var data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const key_z = std.heap.c_allocator.dupeSentinel(u8, key, 0) catch return API_OUT_OF_MEMORY;
    defer std.heap.c_allocator.free(key_z);
    const result = api_backend.get(data.op.ctx, data.value, key_z);
    if (!drainApiJobs(&data.op)) {
        discardBackendResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn js_bay_value_set(object: u64, key_arg: Utf8, value: u64, out_exception: *u64) c_int {
    out_exception.* = 0;
    const key = checkedUtf8(key_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(key) or !noEmbeddedNul(key)) return API_INVALID_ARGUMENT;
    var object_data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer object_data.deinit();
    // Allocate before duplicating `value`: a key-allocation failure must not leave a protected/reference-counted duplicate without an owner.
    const key_z = duplicateKey(key) orelse return API_OUT_OF_MEMORY;
    defer std.heap.c_allocator.free(key_z);
    const pinned_value = switch (pinValue(object_data.op, value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    const result = api_backend.set(object_data.op.ctx, object_data.value, key_z, pinned_value);
    if (!drainApiJobs(&object_data.op)) {
        discardBackendResult(object_data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.exception) |exception| {
        const stored = apiStore(object_data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    return API_OK;
}
pub export fn js_bay_value_call(function: u64, this_value: u64, args: ?[*]const u64, argc: usize, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    if (args == null and argc != 0) return API_INVALID_ARGUMENT;
    var function_data = switch (beginValueOp(function)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer function_data.deinit();
    const pinned_this = switch (pinValue(function_data.op, this_value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer ActiveEngine.freeValue(function_data.op.ctx, pinned_this);
    var values = std.ArrayList(ActiveEngine.Value).empty;
    defer values.deinit(std.heap.c_allocator);
    defer for (values.items) |item| ActiveEngine.freeValue(function_data.op.ctx, item);
    if (args) |raw_args| for (raw_args[0..argc]) |handle| {
        const item = switch (pinValue(function_data.op, handle)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        values.append(std.heap.c_allocator, item) catch {
            ActiveEngine.freeValue(function_data.op.ctx, item);
            return API_OUT_OF_MEMORY;
        };
    };
    const result = api_backend.call(function_data.op.ctx, function_data.value, pinned_this, values.items);
    if (!drainApiJobs(&function_data.op)) {
        discardBackendResult(function_data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(function_data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(function_data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn js_bay_value_construct(function: u64, args: ?[*]const u64, argc: usize, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    if (args == null and argc != 0) return API_INVALID_ARGUMENT;
    var function_data = switch (beginValueOp(function)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer function_data.deinit();
    var values = std.ArrayList(ActiveEngine.Value).empty;
    defer values.deinit(std.heap.c_allocator);
    defer for (values.items) |item| ActiveEngine.freeValue(function_data.op.ctx, item);
    if (args) |raw_args| for (raw_args[0..argc]) |handle| {
        const item = switch (pinValue(function_data.op, handle)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        values.append(std.heap.c_allocator, item) catch {
            ActiveEngine.freeValue(function_data.op.ctx, item);
            return API_OUT_OF_MEMORY;
        };
    };
    const result = api_backend.construct(function_data.op.ctx, function_data.value, values.items);
    if (!drainApiJobs(&function_data.op)) {
        discardBackendResult(function_data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(function_data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(function_data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

/// Publish a boolean backend result, or its original throw value, once the microtask checkpoint has run. A checkpoint that tears the instance down publishes nothing.
fn finishBoolOp(op: *ApiOp, result: api_backend.BoolResult, out_flag: *bool, out_exception: *u64) c_int {
    if (!drainApiJobs(op)) {
        if (result.exception) |exception| ActiveEngine.freeValue(op.ctx, exception);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    out_flag.* = result.value;
    return API_OK;
}

fn keyedBoolOp(
    comptime backendOp: fn (ActiveEngine.Context, ActiveEngine.Value, [:0]const u8) api_backend.BoolResult,
    object: u64,
    key_arg: Utf8,
    out_flag: *bool,
    out_exception: *u64,
) c_int {
    out_flag.* = false;
    out_exception.* = 0;
    const key = checkedUtf8(key_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(key) or !noEmbeddedNul(key)) return API_INVALID_ARGUMENT;
    var data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const key_z = duplicateKey(key) orelse return API_OUT_OF_MEMORY;
    defer std.heap.c_allocator.free(key_z);
    return finishBoolOp(&data.op, backendOp(data.op.ctx, data.value, key_z), out_flag, out_exception);
}

pub export fn js_bay_value_has(object: u64, key: Utf8, out_has: *bool, out_exception: *u64) c_int {
    return keyedBoolOp(api_backend.has, object, key, out_has, out_exception);
}

pub export fn js_bay_value_delete(object: u64, key: Utf8, out_deleted: *bool, out_exception: *u64) c_int {
    return keyedBoolOp(api_backend.delete, object, key, out_deleted, out_exception);
}

pub export fn js_bay_value_keys(object: u64, out_array: *u64, out_exception: *u64) c_int {
    out_array.* = 0;
    out_exception.* = 0;
    var data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.keys(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBackendResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_array);
}

pub export fn js_bay_value_instance_of(value: u64, constructor: u64, out_result: *bool, out_exception: *u64) c_int {
    out_result.* = false;
    out_exception.* = 0;
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const pinned_constructor = switch (pinValue(data.op, constructor)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer ActiveEngine.freeValue(data.op.ctx, pinned_constructor);
    return finishBoolOp(&data.op, api_backend.instanceOf(data.op.ctx, data.value, pinned_constructor), out_result, out_exception);
}
test "c_api: set key allocation failure does not retain its value duplicate" {
    if (comptime backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    try std.testing.expect(js_bay_engine_create(id, null, null));
    defer js_bay_engine_destroy(id);
    var object: u64 = 0;
    var value: u64 = 0;
    var exception: u64 = 0;
    try std.testing.expectEqual(API_OK, js_bay_value_new_object(id, &object));
    try std.testing.expectEqual(API_OK, js_bay_value_new_number(id, 1, &value));
    test_only.failNextKeyAllocation();
    try std.testing.expectEqual(API_OUT_OF_MEMORY, js_bay_value_set(object, .{ .data = "x", .len = 1 }, value, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqual(API_OK, js_bay_value_release(value));
    try std.testing.expectEqual(API_OK, js_bay_value_release(object));
}

fn bindOomCallback(_: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    return API_OK;
}

var bind_oom_finalize_count = std.atomic.Value(u32).init(0);

fn bindOomFinalize(_: ?*anyopaque) callconv(.c) void {
    _ = bind_oom_finalize_count.fetchAdd(1, .seq_cst);
}

test "c_api: bind OOM clears the pending QuickJS exception" {
    if (comptime backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    const m = backend.ActiveEngineModule;
    bind_oom_finalize_count.store(0, .seq_cst);
    try std.testing.expect(js_bay_engine_create(id, null, null));
    defer js_bay_engine_destroy(id);
    try std.testing.expect(js_bay_engine_set_memory_limit(id, 1));
    defer _ = js_bay_engine_set_memory_limit(id, 0);
    var held: [128]u64 = @splat(0);
    var count: usize = 0;
    while (count < held.len) : (count += 1) {
        var out: u64 = 99;
        var exception: u64 = 98;
        var name: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&name, "bind_oom_{d}", .{count});
        const status = js_bay_engine_bind(id, .{ .data = text.ptr, .len = text.len }, &bindOomCallback, null, &bindOomFinalize, &out, &exception);
        if (status == API_OK) {
            held[count] = out;
            continue;
        }
        try std.testing.expectEqual(API_OUT_OF_MEMORY, status);
        try std.testing.expect(out == 0 and exception == 0);
        try std.testing.expectEqual(@as(u32, 0), bind_oom_finalize_count.load(.seq_cst));
        const ctx = engine.getContext(id) orelse return error.NoContext;
        if (@TypeOf(m.qjs.JS_HasException(ctx)) == bool) {
            try std.testing.expect(!m.qjs.JS_HasException(ctx));
        } else {
            try std.testing.expect(m.qjs.JS_HasException(ctx) == 0);
        }
        for (held[0..count]) |value| try std.testing.expectEqual(API_OK, js_bay_value_release(value));
        try std.testing.expect(js_bay_engine_set_memory_limit(id, 0));
        var recovered: u64 = 0;
        exception = 0;
        try std.testing.expectEqual(API_OK, js_bay_engine_evaluate(id, .{ .data = "6*7", .len = 3 }, .{ .data = "bind.js", .len = 7 }, null, &recovered, &exception));
        try std.testing.expect(recovered != 0 and exception == 0);
        var number: f64 = 0;
        try std.testing.expectEqual(API_OK, js_bay_value_to_number(recovered, &number));
        try std.testing.expectEqual(@as(f64, 42), number);
        try std.testing.expectEqual(API_OK, js_bay_value_release(recovered));
        return;
    }
    return error.NoOom;
}

pub export fn js_bay_engine_bind(instance_id_raw: c_int, name_arg: Utf8, callback: ?api_bind.Callback, user_data: ?*anyopaque, finalize: ?api_bind.Finalize, out_function: *u64, out_exception: *u64) c_int {
    out_function.* = 0;
    out_exception.* = 0;
    const name = checkedUtf8(name_arg) orelse return API_INVALID_ARGUMENT;
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or !noEmbeddedNul(name)) return API_INVALID_ARGUMENT;
    const cb = callback orelse return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id_raw);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const installed = api_bind.install(id, op.ctx, name, cb, user_data, finalize);
    switch (installed) {
        .out_of_memory => return API_OUT_OF_MEMORY,
        .exception => |exception| {
            const stored = apiStore(id, exception, out_exception);
            return if (stored == API_OK) 1 else stored;
        },
        .installed => |ok| {
            const stored = apiStore(id, ok.function, out_function);
            if (stored == API_OK) api_bind.commit(ok.binding) else api_bind.abort(ok.binding);
            return stored;
        },
    }
}

pub const NativeSyncStart = *const fn (i32, ?*anyopaque, u64, u64, usize, ?[*]const u64) callconv(.c) void;

const SyncBinding = struct {
    start: NativeSyncStart,
    user_data: ?*anyopaque,
    finalize: ?api_bind.Finalize,
    timeout_ms: u64,
};

fn syncBindingFinalize(data: ?*anyopaque) callconv(.c) void {
    const binding: *SyncBinding = @ptrCast(@alignCast(data orelse return));
    if (binding.finalize) |finalize| finalize(binding.user_data);
    std.heap.c_allocator.destroy(binding);
}

fn syncError(instance_id: i32, message: []const u8, out_exception: *u64) c_int {
    const status = js_bay_value_new_error(instance_id, .{ .data = message.ptr, .len = message.len }, out_exception);
    return if (status == API_OK) API_EXCEPTION else status;
}

fn syncTrampoline(instance_id: i32, data: ?*anyopaque, this_value: u64, argc: usize, args: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const binding: *SyncBinding = @ptrCast(@alignCast(data orelse return API_INSTANCE_NOT_FOUND));
    // This covers the host start callback and the native wait. A host may receive queued work while here, but a reentrant tick must not execute it.
    var sync_wait = @import("runtime/js_scheduler.zig").beginSyncWait(instance_id) orelse return API_INSTANCE_NOT_FOUND;
    defer sync_wait.end();
    const started = native_sync.start(instance_id) orelse return API_OUT_OF_MEMORY;
    defer native_sync.finish(started.id, started.request);

    const started_at: u64 = @intCast(@import("platform/io.zig").monotonicMilliseconds());
    var deadline = std.math.add(u64, started_at, binding.timeout_ms) catch std.math.maxInt(u64);
    if (runtime_control.executionDeadlineMillis(instance_id)) |execution_deadline| deadline = @min(deadline, execution_deadline);
    native_sync.tightenDeadline(started.request, deadline);

    // The host start callback receives borrowed JS handles only while it is running. It may complete inline, but must otherwise hand only the ID to its system completion path.
    if (runtime_control.isInterruptRequested(instance_id)) {
        native_sync.cancel(started.id);
    } else {
        binding.start(instance_id, binding.user_data, started.id, this_value, argc, args);
    }

    // A start callback can arm a shorter execution budget. Re-snapshot its absolute deadline after it returns, then tighten the request before waiting; a completion arriving after that deadline cannot win.
    if (runtime_control.executionDeadlineMillis(instance_id)) |execution_deadline| {
        deadline = @min(deadline, execution_deadline);
        native_sync.tightenDeadline(started.request, deadline);
    }
    const completed = native_sync.wait(started.request);
    switch (completed.outcome) {
        .ok, .exception => {
            const json = completed.json orelse return syncError(instance_id, "native sync completion omitted JSON", out_exception);
            var parsed: u64 = 0;
            var parse_exception: u64 = 0;
            const parsed_status = js_bay_value_new_json(instance_id, .{ .data = json.ptr, .len = json.len }, &parsed, &parse_exception);
            if (parsed_status != API_OK) {
                out_exception.* = parse_exception;
                return if (parsed_status == API_EXCEPTION) API_EXCEPTION else parsed_status;
            }
            if (completed.outcome == .ok) {
                out_value.* = parsed;
                return API_OK;
            }
            out_exception.* = parsed;
            return API_EXCEPTION;
        },
        .timeout => return syncError(instance_id, "native sync operation timed out", out_exception),
        .cancelled => return syncError(instance_id, "native sync operation cancelled", out_exception),
    }
}

/// Publish a native operation that synchronously waits for a data-only completion. See include/js_bay_sync.h for the cross-thread contract.
pub export fn js_bay_engine_bind_sync(instance_id_raw: c_int, name_arg: Utf8, start: ?NativeSyncStart, user_data: ?*anyopaque, finalize: ?api_bind.Finalize, timeout_ms: u64, out_function: *u64, out_exception: *u64) c_int {
    out_function.* = 0;
    out_exception.* = 0;
    const name = checkedUtf8(name_arg) orelse return API_INVALID_ARGUMENT;
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or !noEmbeddedNul(name) or timeout_ms == 0) return API_INVALID_ARGUMENT;
    const start_fn = start orelse return API_INVALID_ARGUMENT;
    const binding = std.heap.c_allocator.create(SyncBinding) catch return API_OUT_OF_MEMORY;
    binding.* = .{ .start = start_fn, .user_data = user_data, .finalize = finalize, .timeout_ms = timeout_ms };
    const status = js_bay_engine_bind(instance_id_raw, name_arg, &syncTrampoline, binding, &syncBindingFinalize, out_function, out_exception);
    if (status != API_OK) std.heap.c_allocator.destroy(binding);
    return status;
}

/// Data-only completion entry point. It is safe on a non-owner thread.
pub export fn js_bay_sync_complete(request_id: u64, outcome_status: c_int, json_arg: Utf8) c_int {
    const json = checkedUtf8(json_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(json)) return API_INVALID_ARGUMENT;
    const outcome: native_sync.Outcome = switch (outcome_status) {
        API_OK => .ok,
        API_EXCEPTION => .exception,
        else => return API_INVALID_ARGUMENT,
    };
    return switch (native_sync.complete(request_id, outcome, json)) {
        .ok => API_OK,
        .stale => API_STALE_VALUE,
        .out_of_memory => API_OUT_OF_MEMORY,
    };
}

// ---- Event loop (optional, for platforms that need it) ----

fn testThreadRun_event_loop_once(instance_id: c_int) void {
    engine.runEventLoopOnce(@intCast(instance_id));
}

fn testThreadRun_event_loop(instance_id: c_int) void {
    engine.runEventLoop(@intCast(instance_id));
}

pub fn js_bay_engine_stop_event_loop(instance_id: c_int) void {
    engine.stopEventLoop(@intCast(instance_id));
}

fn testDispatchCString(instance_id: c_int, script: [*:0]const u8) bool {
    return engine.dispatchTask(@intCast(instance_id), script);
}

// ---- Internal helpers ----

fn sliceToCString(slice: []const u8) ?[*:0]const u8 {
    const z = std.heap.c_allocator.allocSentinel(u8, slice.len, 0) catch return null;
    @memcpy(z, slice);
    return z.ptr;
}

// ===========================================================================
// bytecode.zig
// ===========================================================================

pub export fn js_bay_engine_compile_bytecode(
    instance_id: c_int,
    source_arg: Utf8,
    filename_arg: Utf8,
    out_bytes: *Bytes,
    out_exception: *u64,
) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    const source = checkedUtf8(source_arg) orelse return API_INVALID_ARGUMENT;
    const filename = checkedUtf8(filename_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(filename) or !noEmbeddedNul(filename)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = typed_bytecode.compile(op.ctx, source, filename);
    if (!drainApiJobs(&op)) {
        discardTypedBytecodeResult(op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.unsupported) return API_UNSUPPORTED;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) API_EXCEPTION else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}

pub export fn js_bay_engine_run_bytecode(
    instance_id: c_int,
    bytes: ?[*]const u8,
    bytes_len: usize,
    out_value: *u64,
    out_exception: *u64,
) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const input: []const u8 = if (bytes) |ptr| ptr[0..bytes_len] else if (bytes_len == 0) "" else return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = typed_bytecode.run(op.ctx, input);
    if (!drainApiJobs(&op)) {
        discardTypedBytecodeResult(op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.unsupported) return API_UNSUPPORTED;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) API_EXCEPTION else stored;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

// ---------------------------------------------------------------------------
// Engine thread, host callbacks, and pointer+length eval.
// ---------------------------------------------------------------------------

fn bytesOf(ptr: [*]const u8, len: usize) []const u8 {
    if (len == 0) return "";
    return ptr[0..len];
}

fn testThreadId(instance_id: c_int) u64 {
    return engine_thread.threadId(@intCast(instance_id));
}

fn testThreadPost(
    instance_id: c_int,
    src: [*]const u8,
    src_len: usize,
    filename: [*]const u8,
    filename_len: usize,
) u64 {
    return engine_thread.postScript(
        @intCast(instance_id),
        bytesOf(src, src_len),
        bytesOf(filename, filename_len),
    );
}

fn testThreadWait(
    instance_id: c_int,
    job_id: u64,
    timeout_ms: u64,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    return engine_thread.waitJob(@intCast(instance_id), job_id, timeout_ms, out_result, out_error);
}

fn testThreadBarrier(instance_id: c_int, timeout_ms: u64) c_int {
    return engine_thread.barrier(@intCast(instance_id), timeout_ms);
}

fn testThreadRun(
    instance_id: c_int,
    src: [*]const u8,
    src_len: usize,
    filename: [*]const u8,
    filename_len: usize,
    timeout_ms: u64,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    return engine_thread.runScript(
        @intCast(instance_id),
        bytesOf(src, src_len),
        bytesOf(filename, filename_len),
        timeout_ms,
        out_result,
        out_error,
    );
}

fn testThreadEvalCString(
    instance_id: c_int,
    src: [*]const u8,
    src_len: usize,
    filename: [*]const u8,
    filename_len: usize,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    return engine_thread.evalBytes(
        @intCast(instance_id),
        bytesOf(src, src_len),
        bytesOf(filename, filename_len),
        out_result,
        out_error,
    );
}

comptime {
    @export(&js_bay_engine_create, .{ .name = "js_bay_engine_create" });
    @export(&js_bay_engine_destroy, .{ .name = "js_bay_engine_destroy" });
    @export(&js_bay_engine_request_interrupt, .{ .name = "js_bay_engine_request_interrupt" });
    @export(&js_bay_engine_clear_interrupt, .{ .name = "js_bay_engine_clear_interrupt" });
    @export(&js_bay_engine_set_execution_time_limit, .{ .name = "js_bay_engine_set_execution_time_limit" });
    @export(&js_bay_engine_set_memory_limit, .{ .name = "js_bay_engine_set_memory_limit" });
    @export(&js_bay_engine_get_memory_usage, .{ .name = "js_bay_engine_get_memory_usage" });
    @export(&js_bay_engine_run_gc, .{ .name = "js_bay_engine_run_gc" });
    @export(&js_bay_engine_set_event_handler, .{ .name = "js_bay_engine_set_event_handler" });
}

// Test-only intentional native fault. Exported ONLY when built with `-Dfault-injection=true`.
// Never part of the published product ABI. See tests/process-isolation/ and docs/host-isolation.md.
comptime {
    if (@import("build_options").fault_injection) {
        const fault = struct {
            fn trigger(kind: c_int) callconv(.c) void {
                switch (kind) {
                    // 1: hard segfault via low-address store (kills same-process hosts).
                    1 => {
                        const p: *volatile u8 = @ptrFromInt(1);
                        p.* = 0x41;
                    },
                    // 2: Zig panic (typically abort / noreturn trap).
                    2 => std.debug.panic("js_bay intentional fault injection", .{}),
                    // 0 / default: process abort.
                    else => std.process.abort(),
                }
            }
        };
        @export(&fault.trigger, .{ .name = "js_bay_test_trigger_native_fault" });
    }
}
