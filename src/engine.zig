//! Engine instance lifecycle.
//!
//! Safety contract: all operations on a given instance_id MUST happen on a single thread. The JS engine and its timer scheduler are not thread-safe per instance.

const std = @import("std");
const backend = @import("backend.zig");
const instance_map = @import("runtime/instance_map.zig");
const timers = @import("runtime/timers.zig");
const types = @import("types.zig");
const debugger_mod = @import("inspector/debugger.zig");
const dispatch = @import("runtime/dispatch.zig");

const ActiveEngine = backend.ActiveEngine;

pub const EvalResult = types.EvalResult;
pub const instance_not_found_err = "Instance not found";

fn missingInstanceResult() EvalResult {
    return .{ .result = null, .err = instance_not_found_err, .err_is_heap = false };
}

/// A transport close can leave Inspector cleanup pending when its owner task could not be posted. Check again at the concrete evaluator boundary: the context is now admitted and any direct host evaluation must not execute with the former session's debugger hook still armed.
fn reconcileInspectorBeforeEvaluation(instance_id: i32) void {
    if (comptime @import("build_options").inspector) {
        if (@import("inspector/root.zig").state.hasPendingAsyncDepthReconciliation()) {
            @import("inspector/root.zig").debugger_cdp.reconcilePendingAsyncDepthOnOwner(instance_id);
        }
    }
}

var create_before_debugger_attach_hook_for_testing: ?*const fn (i32, ?*anyopaque) void = null;
var create_hook_context_for_testing: ?*anyopaque = null;
var create_after_insert_hook_for_testing: ?*const fn (i32, ?*anyopaque) void = null;
var create_after_insert_context_for_testing: ?*anyopaque = null;

pub fn setCreateBeforeDebuggerAttachHookForTesting(hook: ?*const fn (i32, ?*anyopaque) void, ctx: ?*anyopaque) void {
    create_before_debugger_attach_hook_for_testing = hook;
    create_hook_context_for_testing = ctx;
}

pub fn setCreateAfterInsertHookForTesting(hook: ?*const fn (i32, ?*anyopaque) void, ctx: ?*anyopaque) void {
    create_after_insert_hook_for_testing = hook;
    create_after_insert_context_for_testing = ctx;
}

/// End a JS entry lease and perform a destroy requested by one of its native callbacks only after the outermost entry has left the runtime.
pub fn finishEvalEntry(instance_id: i32, lease: @import("runtime/engine_thread.zig").EvalLease) void {
    const engine_thread = @import("runtime/engine_thread.zig");
    if (engine_thread.endEvalAndTakeDeferred(lease)) destroyNow(instance_id);
}

pub fn create(instance_id: i32, config: types.EngineConfig) bool {
    return createWithBackend(instance_id, config, backend.active_backend);
}

/// Create-time engine select. `tag` must be packed into this artifact. The pack primary uses the monomorphic ActiveEngine path; other packed tags use erased handles + `backend_dispatch`.
pub fn createWithBackend(instance_id: i32, config: types.EngineConfig, tag: backend.BackendType) bool {
    @import("runtime/scheduler_gate.zig").set(.{ .enter = @import("runtime/js_scheduler.zig").backendDrainAllowed, .leave = @import("runtime/js_scheduler.zig").backendDrainFinished });
    if (instance_map.getPtrs(instance_id) != null) return false;
    if (!backend.isPacked(tag)) return false;

    const loop = event_loop.Driver.create(std.heap.c_allocator) catch return false;
    const backend_dispatch = @import("backend_dispatch.zig");

    if (tag == backend.active_backend) {
        const runtime = blk: {
            if (comptime backend.isHermesBackend(backend.active_backend)) {
                const build_opts = @import("build_options");
                const from_config: u64 = config.max_heap_size;
                const from_build: u64 = build_opts.hermes_max_heap;
                const max_heap: u64 = if (from_config != 0) from_config else from_build;
                break :blk @import("backend/hermes/lifecycle.zig").newRuntimeWithMaxHeap(max_heap);
            }
            break :blk ActiveEngine.newRuntime();
        } orelse {
            loop.destroy();
            return false;
        };
        ActiveEngine.setMaxStackSize(runtime, config.max_stack_size);

        const ctx = ActiveEngine.newContext(runtime) orelse {
            ActiveEngine.freeRuntime(runtime);
            loop.destroy();
            return false;
        };

        ActiveEngine.setContextOpaque(ctx, @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(instance_id))))));

        if (config.module_loader) |ml| {
            switch (backend.active_backend) {
                .quickjs, .quickjs_ng => {
                    const qjs_mod = @import("backend.zig").ActiveEngineModule;
                    qjs_mod.installModuleLoader(runtime, ml);
                },
                .jsc => {
                    const jsc_mod = @import("backend/jsc.zig");
                    jsc_mod.installModuleLoader(ctx, ml);
                },
                .escargot => {
                    if (comptime backend.isEscargotBackend(backend.active_backend)) {
                        @import("backend/escargot.zig").installModuleLoader(ctx, ml);
                    }
                },
                .hermes => {
                    if (comptime backend.isHermesBackend(backend.active_backend)) {
                        @import("backend/hermes.zig").installModuleLoader(ctx, ml);
                    }
                },
            }
        }

        ActiveEngine.registerConsole(ctx);
        ActiveEngine.registerTimers(ctx);

        const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
            ActiveEngine.freeContext(ctx);
            ActiveEngine.freeRuntime(runtime);
            loop.destroy();
            return false;
        };
        const resources = @import("runtime/resource_limits.zig").Budget.create(config.resource_limits) orelse {
            ActiveEngine.freeContext(ctx);
            ActiveEngine.freeRuntime(runtime);
            loop.destroy();
            std.heap.c_allocator.destroy(instance);
            return false;
        };
        instance.* = .{
            .resources = resources,
            .instance_id = instance_id,
            .engine_handles = .{ .mono = .{ .runtime = runtime, .ctx = ctx } },
            .loop = loop,
            .timers = timers.TimerRegistry.init(),
            .log_handler = config.log_handler,
            .log_user_data = config.log_user_data,
        };

        if (!@import("builtin").is_test) instance.timers.clock_now = loop.now();

        if (create_before_debugger_attach_hook_for_testing) |hook| hook(instance_id, create_hook_context_for_testing);

        if (!instance_map.insertWith(instance, struct {
            pub fn call(_: @This(), registered: *instance_map.EngineInstance) bool {
                if (!@import("runtime/runtime_control.zig").initForInstance(registered.instance_id, registered)) return false;
                if (create_after_insert_hook_for_testing) |hook| hook(registered.instance_id, create_after_insert_context_for_testing);
                return true;
            }
        }{})) {
            ActiveEngine.freeContext(ctx);
            ActiveEngine.freeRuntime(runtime);
            loop.destroy();
            resources.deinit();
            instance.deinitSynchronization();
            std.heap.c_allocator.destroy(instance);
            return false;
        }
        return true;
    }

    // Non-primary packed backend: bare lifecycle for create/eval/destroy plus the typed Value surface.
    const handles = backend_dispatch.createPacked(tag) orelse {
        loop.destroy();
        return false;
    };
    backend_dispatch.finishCreate(tag, handles, instance_id, config.max_stack_size);

    const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        return false;
    };
    const resources = @import("runtime/resource_limits.zig").Budget.create(config.resource_limits) orelse {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        std.heap.c_allocator.destroy(instance);
        return false;
    };
    instance.* = .{
        .resources = resources,
        .instance_id = instance_id,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles.runtime_addr, .ctx_addr = handles.ctx_addr } },
        .loop = loop,
        .timers = timers.TimerRegistry.init(),
        .log_handler = config.log_handler,
        .log_user_data = config.log_user_data,
    };
    if (!@import("builtin").is_test) instance.timers.clock_now = loop.now();

    // Install interrupt/time-limit control for packed-alt by instance backend (same as primary). Debugger attach remains primary-only.
    if (!instance_map.insertWith(instance, struct {
        pub fn call(_: @This(), registered: *instance_map.EngineInstance) bool {
            if (!@import("runtime/runtime_control.zig").initForInstance(registered.instance_id, registered)) return false;
            if (create_after_insert_hook_for_testing) |hook| hook(registered.instance_id, create_after_insert_context_for_testing);
            return true;
        }
    }{})) {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        resources.deinit();
        instance.deinitSynchronization();
        std.heap.c_allocator.destroy(instance);
        return false;
    }
    return true;
}

pub fn evalScript(instance_id: i32, script: []const u8, filename: []const u8) EvalResult {
    // After threadStart, only the engine thread may eval. A foreign call fails here and does not run the script. Before the thread starts, and after it stops, the caller may eval.
    if (instance_map.getPtrs(instance_id) == null) {
        return missingInstanceResult();
    }
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) {
        // The instance can disappear after the initial lookup while destroy closes public JS admission. Preserve the destroyed-instance result shape instead of reporting a thread-affinity error.
        if (instance_map.getPtrs(instance_id) == null) {
            return missingInstanceResult();
        }
        return .{
            .result = null,
            .err = engine_thread.foreign_eval_err,
            .err_is_heap = false,
        };
    }
    const ptrs = instance_map.getPtrs(instance_id) orelse
        return missingInstanceResult();
    const inst = instance_map.getInstance(instance_id) orelse return missingInstanceResult();
    var execution = @import("runtime/js_scheduler.zig").beginExecution(instance_id) orelse return missingInstanceResult();
    @import("inspector/root.zig").drainRetired(instance_id);
    reconcileInspectorBeforeEvaluation(instance_id);
    debugger_mod.noteScript(instance_id, filename, script);
    debugger_mod.clearExceptionHold(instance_id);
    const result = switch (inst.engine_handles) {
        .mono => |m| ActiveEngine.eval(m.ctx, script, filename),
        .packed_alt => |a| @import("backend_dispatch.zig").evalPacked(a.tag, .{ .runtime_addr = a.runtime_addr, .ctx_addr = a.ctx_addr }, script, filename),
    };
    execution.end();
    switch (inst.engine_handles) {
        .mono => |m| @import("runtime/js_scheduler.zig").checkpoint(instance_id, m.ctx),
        .packed_alt => |a| @import("backend_dispatch.zig").processPendingJobsPacked(a.tag, .{ .runtime_addr = a.runtime_addr, .ctx_addr = a.ctx_addr }),
    }
    _ = ptrs;
    if (result.err) |message| @import("inspector/root.zig").exceptions.reportUncaught(instance_id, message, filename);
    return result;
}

/// Evaluate through the same admission, debugger and teardown boundary as `evalScript`, while preserving a live value or raw throw for callers that must choose their own serialization.
pub fn evalScriptTyped(instance_id: i32, script: []const u8, filename: []const u8) ?@import("script/typed_eval.zig").Result {
    var entry = @import("runtime/engine_thread.zig").beginTypedEval(instance_id, script, filename) orelse return null;
    defer _ = entry.finish();
    return entry.result;
}

/// Evaluate JavaScript as an ES module. Top-level `import` statements are resolved via `EngineConfig.module_loader` if configured; otherwise module imports raise a ReferenceError at evaluation time.
///
/// JSC backend: returns an error `EvalResult` ("JSC backend does not support ES modules (use QuickJS)"). Use `evalScript` or switch to the QuickJS backend.
pub fn evalModule(instance_id: i32, source: []const u8, filename: []const u8) EvalResult {
    if (instance_map.getPtrs(instance_id) == null) return missingInstanceResult();
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) {
        if (instance_map.getPtrs(instance_id) == null) return missingInstanceResult();
        return .{
            .result = null,
            .err = engine_thread.foreign_eval_err,
            .err_is_heap = false,
        };
    }
    const ptrs = instance_map.getPtrs(instance_id) orelse
        return missingInstanceResult();
    var execution = @import("runtime/js_scheduler.zig").beginExecution(instance_id) orelse return missingInstanceResult();
    @import("inspector/root.zig").drainRetired(instance_id);
    const result = switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("backend.zig").ActiveEngineModule.evalAsModule(ptrs.ctx, source, filename),
        .jsc => @import("backend/jsc.zig").jscEvalModule(ptrs.ctx, source, filename),
        .escargot => blk: {
            if (comptime !backend.isEscargotBackend(backend.active_backend)) {
                break :blk @as(EvalResult, .{ .result = null, .err = "ES modules not supported on this backend", .err_is_heap = false });
            }
            break :blk @import("backend/escargot.zig").escargotEvalModule(ptrs.ctx, source, filename);
        },
        .hermes => blk: {
            if (comptime !backend.isHermesBackend(backend.active_backend)) {
                break :blk @as(EvalResult, .{ .result = null, .err = "ES modules not supported on this backend", .err_is_heap = false });
            }
            break :blk @import("backend/hermes.zig").hermesEvalModule(ptrs.ctx, source, filename);
        },
    };
    execution.end();
    @import("runtime/js_scheduler.zig").checkpoint(instance_id, ptrs.ctx);
    return result;
}

/// Resolve + load the entry specifier via the configured module loader and evaluate the result as an ES module. Returns an error `EvalResult` when no loader is configured, when the loader returns false, or when the JSC backend is active.
pub fn importModule(instance_id: i32, entry_specifier: []const u8) EvalResult {
    if (instance_map.getPtrs(instance_id) == null) return missingInstanceResult();
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) {
        if (instance_map.getPtrs(instance_id) == null) return missingInstanceResult();
        return .{ .result = null, .err = engine_thread.foreign_eval_err, .err_is_heap = false };
    }
    const ptrs = instance_map.getPtrs(instance_id) orelse
        return missingInstanceResult();
    var execution = @import("runtime/js_scheduler.zig").beginExecution(instance_id) orelse return missingInstanceResult();
    defer {
        execution.end();
        @import("runtime/js_scheduler.zig").checkpoint(instance_id, ptrs.ctx);
    }
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("backend.zig").ActiveEngineModule;
            return qjs_mod.importModuleBySpecifier(ptrs.ctx, entry_specifier);
        },
        .jsc => {
            const jsc_mod = @import("backend/jsc.zig");
            return jsc_mod.jscImportModule(ptrs.ctx, entry_specifier);
        },
        .escargot => {
            if (comptime !backend.isEscargotBackend(backend.active_backend)) {
                return .{ .result = null, .err = "ES modules not supported on this backend", .err_is_heap = false };
            }
            return @import("backend/escargot.zig").escargotImportModule(ptrs.ctx, entry_specifier);
        },
        .hermes => {
            if (comptime !backend.isHermesBackend(backend.active_backend)) {
                return .{ .result = null, .err = "ES modules not supported on this backend", .err_is_heap = false };
            }
            return @import("backend/hermes.zig").hermesImportModule(ptrs.ctx, entry_specifier);
        },
    }
}

pub fn evalFile(instance_id: i32, path: []const u8) EvalResult {
    if (instance_map.getPtrs(instance_id) == null) return missingInstanceResult();
    const content = readFile(path) catch |e| {
        const msg = std.fmt.allocPrint(std.heap.c_allocator, "Failed to read file {s}: {}", .{ path, e }) catch
            return .{ .result = null, .err = "Failed to read file", .err_is_heap = false };
        return .{ .result = null, .err = msg, .err_is_heap = true };
    };
    defer std.heap.c_allocator.free(content);

    return evalScript(instance_id, content, path);
}

fn readFile(path: []const u8) ![]u8 {
    const path_z = try std.heap.c_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.c_allocator.free(path_z);
    @memcpy(path_z, path);
    const file = std.c.fopen(path_z, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(file);

    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(std.heap.c_allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = std.c.fread(&buffer, 1, buffer.len, file);
        if (count != 0) {
            if (content.items.len + count > 10 * 1024 * 1024) return error.FileTooLarge;
            try content.appendSlice(std.heap.c_allocator, buffer[0..count]);
        }
        if (count < buffer.len) {
            if (fileError(file) != 0) return error.ReadFailed;
            if (fileEof(file) != 0) break;
        }
    }
    return content.toOwnedSlice(std.heap.c_allocator);
}

extern "c" fn ferror(file: *std.c.FILE) c_int;
extern "c" fn feof(file: *std.c.FILE) c_int;

fn fileError(file: *std.c.FILE) c_int {
    return ferror(file);
}

fn fileEof(file: *std.c.FILE) c_int {
    return feof(file);
}

const event_loop = @import("js_event_loop");

const TurnContext = struct {
    instance_id: i32,
    native_completion: ?dispatch.TaskCompletion = null,
    fn self(context: ?*anyopaque) *TurnContext {
        return @ptrCast(@alignCast(context.?));
    }
    fn beforeTurn(context: ?*anyopaque) bool {
        const id = self(context).instance_id;
        @import("runtime/engine_thread.zig").onLoopAsync(id);
        return !@import("runtime/engine_thread.zig").ownerHasYielded(id) and !instance_map.isTeardownPending(id);
    }
    fn prepare(context: ?*anyopaque, now: u64) bool {
        const id = self(context).instance_id;
        const started = timers.beginTick(id, now) orelse return false;
        if (started.reentrant) return false;
        @import("inspector/root.zig").drainRetired(id);
        return true;
    }
    fn finishTurn(context: ?*anyopaque) void {
        timers.endTick(self(context).instance_id);
    }
    fn runOneTask(context: ?*anyopaque, source: event_loop.Scheduler.TaskSource, now: u64) bool {
        const turn = self(context);
        if (instance_map.isTeardownPending(turn.instance_id)) return false;
        return switch (source) {
            .host_script => runOneAsync(turn.instance_id),
            .native_dispatch => dispatch.runOneTask(turn.instance_id, &turn.native_completion),
            .tsfn => @import("runtime/tsfn.zig").runOne(turn.instance_id),
            .timer => timers.fireOneDue(turn.instance_id, now),
        };
    }
    fn checkpoint(context: ?*anyopaque) void {
        const id = self(context).instance_id;
        if (!instance_map.isTeardownPending(id)) @import("runtime/js_scheduler.zig").checkpointInstance(id);
    }
    fn finishTask(context: ?*anyopaque) void {
        if (self(context).native_completion) |*completion| completion.finish();
        self(context).native_completion = null;
    }
    fn nextTaskDeadline(context: ?*anyopaque) ?u64 {
        return instance_map.withInstanceReturn(self(context).instance_id, struct {
            pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?u64 {
                inst.task_mutex.lock();
                const has_host_task = inst.task_queue.pendingLen() != 0;
                inst.task_mutex.unlock();
                if (has_host_task) return 0;
                inst.native_task_queue.mutex.lock();
                const has_native_task = inst.native_task_queue.pendingLen() != 0;
                inst.native_task_queue.mutex.unlock();
                if (has_native_task or @import("runtime/tsfn.zig").hasPending(inst.instance_id)) return 0;
                return timers.nextDeadline(inst);
            }
        }{});
    }
    fn shouldStop(context: ?*anyopaque) bool {
        return instance_map.isTeardownPending(self(context).instance_id);
    }
    fn hooks(self_: *TurnContext) event_loop.Driver.Hooks {
        return .{ .context = self_, .before_turn = beforeTurn, .prepare = prepare, .finish_turn = finishTurn, .run_one_task = runOneTask, .checkpoint = checkpoint, .finish_task = finishTask, .next_task_deadline = nextTaskDeadline, .should_stop = shouldStop };
    }
};

/// Execute an admitted event-loop turn using the loop's own clock.
pub fn runEventLoopOnce(instance_id: i32) void {
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return;
    const ptrs = instance_map.getPtrs(instance_id) orelse return;
    var turn = TurnContext{ .instance_id = instance_id };
    event_loop.Driver.integration.runOne(ptrs.loop, turn.hooks());
}

pub const testing = if (@import("builtin").is_test) struct {
    pub fn advance(instance_id: i32, now_ms: i64) i64 {
        if (now_ms < 0) return -1;
        const engine_thread = @import("runtime/engine_thread.zig");
        const lease = engine_thread.beginEval(instance_id);
        defer finishEvalEntry(instance_id, lease);
        if (!lease.allowed) return -1;
        const ptrs = instance_map.getPtrs(instance_id) orelse return -1;
        var turn = TurnContext{ .instance_id = instance_id };
        const next = event_loop.Driver.testing.advance(ptrs.loop, turn.hooks(), @intCast(now_ms)) orelse return -1;
        return @intCast(@min(next, @as(u64, std.math.maxInt(i64))));
    }
} else struct {};

/// Run on the owner thread until stopped; the event loop owns waiting and wakeups.
pub fn runEventLoop(instance_id: i32) void {
    runEventLoopChecked(instance_id) catch {};
}

/// Run the owner loop until stopped. Callers that expose loop admission must preserve the rejection instead of treating it as a completed run.
pub fn runEventLoopChecked(instance_id: i32) event_loop.Driver.Error!void {
    try blockOnLoopChecked(instance_id);
    settleAfterLoop(instance_id);
}

pub fn blockOnLoop(instance_id: i32) void {
    blockOnLoopChecked(instance_id) catch {};
}

pub fn blockOnLoopFor(instance_id: i32, timeout_ms: u64) void {
    runBlockingLoop(instance_id, timeout_ms) catch {};
}

fn blockOnLoopChecked(instance_id: i32) event_loop.Driver.Error!void {
    return runBlockingLoop(instance_id, null);
}

fn runBlockingLoop(instance_id: i32, timeout_ms: ?u64) event_loop.Driver.Error!void {
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return error.AlreadyRunning;
    const ptrs = instance_map.getPtrs(instance_id) orelse return error.AlreadyRunning;
    const loop_scope = engine_thread.beginLoopScope(lease);
    defer engine_thread.endLoopScope(loop_scope);
    if (!loop_scope.allowed) return error.AlreadyRunning;
    var turn = TurnContext{ .instance_id = instance_id };
    if (timeout_ms) |duration| {
        try ptrs.loop.runFor(turn.hooks(), duration);
    } else try ptrs.loop.run(turn.hooks());
}

fn attachedLoopTurn(context: ?*anyopaque) void {
    const instance_id: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(context))));
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return;
    const ptrs = instance_map.getPtrs(instance_id) orelse return;
    var turn = TurnContext{ .instance_id = instance_id };
    ptrs.loop.runAttached(turn.hooks());
}

pub fn attachLoop(instance_id: i32, host: event_loop.Driver.Host) !void {
    const ptrs = instance_map.getPtrs(instance_id) orelse return error.InstanceNotFound;
    try ptrs.loop.attach(host, attachedLoopTurn, @ptrFromInt(@as(usize, @as(u32, @bitCast(instance_id)))));
}

pub fn detachLoop(instance_id: i32) void {
    const ptrs = instance_map.getPtrs(instance_id) orelse return;
    ptrs.loop.detach();
}

/// Drain JS jobs produced while the loop was running, on the engine thread.
pub fn settleAfterLoop(instance_id: i32) void {
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return;
    const ptrs = instance_map.getPtrs(instance_id) orelse return;
    @import("runtime/js_scheduler.zig").checkpoint(instance_id, ptrs.ctx);
    _ = dispatch.tickInstance(instance_id);
}

pub fn stopEventLoop(instance_id: i32) void {
    const ptrs = instance_map.getPtrs(instance_id) orelse return;
    ptrs.loop.requestStop();
}

/// Pause JS scheduling for Hide/Show keep-alive. Safe from any thread.
/// Keeps the VM, binds, timers, and task queues; does not detach the platform Host.
pub fn suspendEventLoop(instance_id: i32) void {
    const ptrs = instance_map.getPtrs(instance_id) orelse return;
    ptrs.loop.suspendScheduling();
}

/// Resume after `suspendEventLoop`. Safe from any thread. Does not recreate state.
pub fn resumeEventLoop(instance_id: i32) void {
    const ptrs = instance_map.getPtrs(instance_id) orelse return;
    ptrs.loop.resumeScheduling();
}

pub fn isEventLoopSuspended(instance_id: i32) bool {
    const ptrs = instance_map.getPtrs(instance_id) orelse return false;
    return ptrs.loop.isSuspended();
}

/// The owned wait primitive remains alive for the lifetime of the instance.
pub fn loopAlive(instance_id: i32) bool {
    return instance_map.getPtrs(instance_id) != null;
}

/// Wake a thread blocked in this instance's event loop. Safe from any thread.
pub fn wakeAsync(instance_id: i32) void {
    instance_map.withInstance(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) void {
            inst.loop.wake();
        }
    }{});
    @import("js_event_loop").host_wake.notify(instance_id);
}

/// Force a synchronous garbage collection cycle. Exposed primarily for tests that need deterministic collection of weakly-referenced objects.
///
/// - QuickJS: calls `JS_RunGC` (sync, aggressive).
/// - JSC: calls `JSSynchronousEdenCollectForDebugging` followed by `JSSynchronousGarbageCollectForDebugging`. The two-phase sequence is required to both promote and then sweep weak handles — a single full-heap collection alone may leave weak refs dangling for a cycle.
pub fn runGc(instance_id: i32) void {
    const engine_thread = @import("runtime/engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return;
    const inst = instance_map.getInstance(instance_id) orelse return;
    switch (inst.engine_handles) {
        .mono => |m| switch (backend.active_backend) {
            .quickjs, .quickjs_ng => ActiveEngine.runGc(m.runtime),
            .jsc => {
                const jsc_mod = @import("backend/jsc.zig");
                jsc_mod.JSSynchronousEdenCollectForDebugging(@ptrCast(m.ctx));
                jsc_mod.JSSynchronousGarbageCollectForDebugging(@ptrCast(m.ctx));
            },
            .escargot, .hermes => ActiveEngine.runGc(m.runtime),
        },
        .packed_alt => |a| @import("backend_dispatch.zig").runGcPacked(a.tag, .{
            .runtime_addr = a.runtime_addr,
            .ctx_addr = a.ctx_addr,
        }),
    }
}

/// Queue a script for the engine thread. Returns false when the instance is unavailable, closing, or its queue cannot accept the script.
pub fn dispatchTask(instance_id: i32, script: [*:0]const u8) bool {
    const dispatched = instance_map.withInstanceReturn(instance_id, struct {
        script: []const u8,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            if (inst.task_admission_closed or inst.teardown_pending) return false;
            inst.task_mutex.lock();
            defer inst.task_mutex.unlock();
            if (!inst.resources.reserve(.script_task, self.script.len)) return false;
            const owned = std.heap.c_allocator.dupeSentinel(u8, self.script, 0) catch {
                inst.resources.release(.script_task, self.script.len);
                return false;
            };
            inst.task_queue.push(std.heap.c_allocator, owned) catch {
                std.heap.c_allocator.free(owned);
                inst.resources.release(.script_task, self.script.len);
                return false;
            };
            inst.loop.wake();
            return true;
        }
    }{ .script = std.mem.span(script) }) orelse false;
    if (dispatched) @import("js_event_loop").host_wake.notify(instance_id);
    return dispatched;
}

/// Destroy an engine instance.
pub fn destroy(instance_id: i32) void {
    const engine_thread = @import("runtime/engine_thread.zig");
    if (engine_thread.isDestroying(instance_id)) return;
    if (engine_thread.isEvalActiveOnCurrentThread(instance_id)) {
        _ = engine_thread.requestDeferredEvalDestroy(instance_id);
        return;
    }
    if (dispatch.isRunningTaskForInstance(instance_id)) {
        const packed_id = @as(usize, @intCast(@as(u32, @bitCast(instance_id)))) + 1;
        if (dispatch.postTask(instance_id, .{
            .ctx = @ptrFromInt(packed_id),
            .run = deferredDestroyTask,
        })) return;
        // A failed enqueue must not free a context while a JS callback is on its stack. Leave teardown to the caller's later destroy attempt.
        return;
    }
    destroyNow(instance_id);
}

fn deferredDestroyTask(ctx: ?*anyopaque) void {
    const packed_id = @intFromPtr(ctx.?) - 1;
    const instance_id: i32 = @bitCast(@as(u32, @truncate(packed_id)));
    destroyNow(instance_id);
}

fn destroyNow(instance_id: i32) void {
    // From this point teardown may detach the engine-thread State before it reaches destroyRuntime. Close public JS admission first so it cannot recreate that State against a runtime being dismantled.
    instance_map.markTeardownPending(instance_id);
    // Mirror stop_loop so a blocking run sees both the teardown latch and the driver's stop bit. shouldStop already watches teardown_pending; requestStop covers hosts that only observe the driver flag and wakes the waiter promptly.
    if (instance_map.getPtrs(instance_id)) |ptrs| {
        ptrs.loop.requestStop();
        ptrs.loop.wake();
    }
    // Synchronous native calls own no JS values, but their owner callback may be asleep on a native condition. Wake it before deferred teardown waits for that callback to unwind.
    @import("js_event_loop").native_sync.cancelForInstance(instance_id);
    // A paused debugger blocks the engine thread inside the current eval. Release that wait before teardown tries to join the thread.
    debugger_mod.abandon(instance_id);
    // On the engine thread the JS call is still on the stack. beginDestroy wakes waiters and returns without freeing; that thread calls destroyRuntime after the call unwinds.
    if (@import("runtime/engine_thread.zig").beginDestroy(instance_id)) return;
    @import("runtime/engine_thread.zig").beforeDestroy(instance_id);
    destroyRuntime(instance_id);
}

/// Free the scheduler and JS runtime for an instance. The caller has already stopped the engine thread, or is that thread and has left the JS call.
pub fn destroyRuntime(instance_id: i32) void {
    const inspector_state = @import("inspector/root.zig").state;
    if (!inspector_state.beginEngineDestroy(instance_id)) return;
    defer inspector_state.endEngineDestroy(instance_id);

    if (!dispatch.closeInstanceTasks(instance_id)) return;
    @import("js_event_loop").host_wake.drop(instance_id);
    // Drain Hide/Show/stop leases before touching the Driver (R3 getPtrs∩destroy).
    instance_map.waitForControlOps(instance_id);
    const instance = instance_map.getInstance(instance_id) orelse return;
    instance.loop.detach();
    // No NativeTask or TSFN callback admitted before closure may still be using this context when runtime teardown starts.
    dispatch.waitForInstanceTasks(instance_id);
    // Stop script dispatch before the JS context is released. A dispatch racing the admission close is serialized by the instance-map mutex.
    instance.task_mutex.lock();
    for (instance.task_queue.pendingSlice()) |task| {
        std.heap.c_allocator.free(task);
        instance.resources.release(.script_task, task.len);
    }
    instance.task_queue.clear(std.heap.c_allocator);
    instance.task_mutex.unlock();

    // Release inspector sockets and the console buffer while the JS context can still free retained remote objects.
    @import("inspector/root.zig").dropInstance(instance_id);

    // No platform callback owns timer state; close the admission path and release timers synchronously while their JS context is still valid.
    timers.cancelAll(instance);

    // Public handles retain backend values and must be invalidated before the context or the reference bookkeeping is released.
    @import("abi/api_bind.zig").dropInstance(instance_id);
    @import("abi/api_value.zig").dropInstance(instance_id);
    @import("abi/packed_api_value.zig").dropInstance(instance_id);
    // TSFN handles pin JS functions and may be called by foreign completion threads. Detach them while this context is live so later completions are rejected instead of touching a destroyed runtime.
    @import("runtime/tsfn.zig").releaseAllForInstance(instance_id);

    // CJS retains JS values and the interrupt handler retains native state read by an executing runtime. Both must outlive admitted JS work, then be released while this context is still valid.
    @import("script/cjs.zig").uninstall(instance_id);
    _ = @import("runtime/runtime_control.zig").deinit(instance_id);

    // 3b. Force-reset any live Global/Weak references so their retained JS values are released BEFORE we tear down the context/runtime. This prevents use-after-free when users forget to call `reset()`.
    forceResetBookkeeping(&instance.ref_bookkeeping);

    @import("backend/console_timers.zig").deinitInstance(instance_id);

    // 4. Free JS context and runtime
    debugger_mod.detach(instance_id);
    switch (instance.engine_handles) {
        .mono => |m| {
            if (m.ctx != null and m.runtime != null) {
                ActiveEngine.runGc(m.runtime);
                ActiveEngine.freeContext(m.ctx);
                ActiveEngine.runGc(m.runtime);
                ActiveEngine.freeRuntime(m.runtime);
            }
        },
        .packed_alt => |a| @import("backend_dispatch.zig").destroyPacked(a.tag, .{ .runtime_addr = a.runtime_addr, .ctx_addr = a.ctx_addr }),
    }
    @import("inspector/async_stack.zig").deinitInstance(instance_id);

    // 5. Free the TimerRegistry and instance
    var timer_reg = instance.timers;
    timer_reg.deinit();

    // Removing the instance under the registry lock excludes concurrent wakeAsync/dispatch calls before the native wait primitive is released.
    const removed = instance_map.remove(instance_id) orelse return;
    removed.resources.deinit();
    removed.loop.destroy();
    removed.deinitSynchronization();
    std.heap.c_allocator.destroy(removed);
}

/// Get the JS context for an instance. Used by consumers to register custom APIs.
pub fn getContext(instance_id: i32) ?ActiveEngine.Context {
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return instance.monoCtx();
}

/// Get the JS runtime for an instance. Inspector startup uses this to create a short-lived clean realm in the same runtime before retaining reflection intrinsics for its own lifetime.
pub fn getRuntime(instance_id: i32) ?ActiveEngine.Runtime {
    const instance = instance_map.getInstance(instance_id) orelse return null;
    return instance.monoRuntime();
}

/// Walk the bookkeeping list, popping each entry and invoking its reset_fn so it can release its retained JS value before the runtime is freed. We unlink entries ourselves so reset_fn does not need to interact with the bookkeeping list (it's already detached by the time it runs).
fn forceResetBookkeeping(book: *instance_map.RefBookkeeping) void {
    while (true) {
        book.mutex.lock();
        const entry = book.head orelse {
            book.mutex.unlock();
            break;
        };
        // Pop from head.
        book.head = entry.next;
        if (book.head) |h| h.prev = null;
        entry.prev = null;
        entry.next = null;
        book.mutex.unlock();

        entry.reset_fn(entry);
    }
}

// ---- Event-loop work ----

fn runOneAsync(instance_id: i32) bool {
    const ptrs = instance_map.getPtrs(instance_id) orelse return false;
    var queued = @import("runtime/js_scheduler.zig").beginQueuedTask(instance_id) orelse return false;
    const PendingScript = struct {
        script: [:0]const u8,
        resources: *@import("runtime/resource_limits.zig").Budget,
    };
    const task = instance_map.withInstanceReturn(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?PendingScript {
            inst.task_mutex.lock();
            defer inst.task_mutex.unlock();
            const script = inst.task_queue.popFront() orelse return null;
            return .{ .script = script, .resources = inst.resources };
        }
    }{}) orelse {
        _ = queued.end();
        return false;
    };
    const script = task.script;
    defer {
        std.heap.c_allocator.free(script);
        task.resources.release(.script_task, script.len);
    }
    const result = ActiveEngine.eval(ptrs.ctx, script, "<dispatch>");
    if (result.result) |value| std.heap.c_allocator.free(@constCast(value));
    if (result.err_is_heap) if (result.err) |value| std.heap.c_allocator.free(@constCast(value));
    _ = queued.end();
    return true;
}

test "engine: packed_alt EngineInstance create/eval/destroy for primary tag (Linux dispatch proof)" {
    // Force the erase/dispatch path even for the pack primary so Linux single-pack CI proves
    // EngineInstance.packed_alt without needing a second real engine (JSC is Apple-only).
    const helpers = @import("tests/test_helpers.zig");
    const id = helpers.nextInstanceId();
    const tag = backend.active_backend;
    const backend_dispatch = @import("backend_dispatch.zig");
    const loop = event_loop.Driver.create(std.heap.c_allocator) catch return error.LoopCreateFailed;
    const handles = backend_dispatch.createPacked(tag) orelse {
        loop.destroy();
        return error.CreatePackedFailed;
    };
    backend_dispatch.finishCreate(tag, handles, id, 256 * 1024);
    const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        return error.Oom;
    };
    const resources = @import("runtime/resource_limits.zig").Budget.create(.{}) orelse {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        std.heap.c_allocator.destroy(instance);
        return error.BudgetFailed;
    };
    instance.* = .{
        .resources = resources,
        .instance_id = id,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles.runtime_addr, .ctx_addr = handles.ctx_addr } },
        .loop = loop,
        .timers = timers.TimerRegistry.init(),
    };
    if (!instance_map.insert(instance)) {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        resources.deinit();
        instance.deinitSynchronization();
        std.heap.c_allocator.destroy(instance);
        return error.InsertFailed;
    }
    defer destroy(id);

    try std.testing.expect(!instance_map.getInstance(id).?.isPrimaryBackend());
    try std.testing.expectEqual(tag, instance_map.getInstance(id).?.backendTag());
    const res = evalScript(id, "40+2", "<packed-alt-proof>");
    defer {
        if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
        if (res.err_is_heap) {
            if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
        }
    }
    try std.testing.expect(res.err == null);
    try std.testing.expectEqualStrings("42", res.result.?);

    // Timers on packed-alt: schedule + one event-loop turn must fire the callback.
    const timed = evalScript(
        id,
        "var __packedAltTimer__ = 0; setTimeout(function () { __packedAltTimer__ = 7; }, 0); __packedAltTimer__;",
        "<packed-alt-timer-arm>",
    );
    defer {
        if (timed.result) |s| std.heap.c_allocator.free(@constCast(s));
        if (timed.err_is_heap) {
            if (timed.err) |e| std.heap.c_allocator.free(@constCast(e));
        }
    }
    try std.testing.expect(timed.err == null);
    try std.testing.expectEqualStrings("0", timed.result.?);
    runEventLoopOnce(id);
    const after = evalScript(id, "__packedAltTimer__", "<packed-alt-timer-check>");
    defer {
        if (after.result) |s| std.heap.c_allocator.free(@constCast(s));
        if (after.err_is_heap) {
            if (after.err) |e| std.heap.c_allocator.free(@constCast(e));
        }
    }
    try std.testing.expect(after.err == null);
    try std.testing.expectEqualStrings("7", after.result.?);
}
