//! JS Bay: Cross-engine JS runtime abstraction layer.
//!
//! Provides a unified API for embedding JavaScript engines (QuickJS / JSC) with an event loop, timers, and console support. Host apps build on top of this.

const backend_mod = @import("backend.zig");

pub const types = @import("types.zig");
pub const value = @import("value/root.zig");
const c_api_impl = @import("c_api.zig");
pub const backend = backend_mod;
// Generic host->JS dispatch helpers. The driver owns execution; this surface only submits or cancels work.
const dispatch_impl = @import("runtime/dispatch.zig");
pub const dispatch = struct {
    pub const NativeTask = dispatch_impl.NativeTask;
    pub const InstanceToken = dispatch_impl.InstanceToken;
    pub const DispatchArg = dispatch_impl.DispatchArg;
    pub const postTask = dispatch_impl.postTask;
    pub const captureInstanceToken = dispatch_impl.captureInstanceToken;
    pub const postTaskWithToken = dispatch_impl.postTaskWithToken;
    pub const callGlobalRetained = dispatch_impl.callGlobalRetained;
    pub const callGlobalRetainedArgs = dispatch_impl.callGlobalRetainedArgs;
    pub const emitGlobal = dispatch_impl.emitGlobal;
    pub const releaseTasksForOwner = dispatch_impl.releaseTasksForOwner;
    pub const isRunningTaskForOwner = dispatch_impl.isRunningTaskForOwner;
};
// Stable host-facing bridge helpers layered on top of dispatch.
pub const host = @import("runtime/host.zig");
// Backend-neutral retained callback/listener support.
pub const listeners = @import("runtime/listeners.zig");
// Typed reference lifecycle (Local/Global/Weak/Scope/StackFrameScope).
pub const reference = @import("value/reference.zig");
// Promise creation / resolution from native code (async boundary helpers).
pub const promise = @import("runtime/promise.zig");
// External values: wrap a raw native pointer as an opaque JS value.
pub const external = @import("value/external.zig");
// Pre-interned property keys (atoms) for fast repeated property access.
pub const atoms = @import("value/atoms.zig");
// Structured JS error inspection/creation (typed errors, stack, name, message).
pub const errors = @import("value/errors.zig");
// Bytecode cache (QuickJS): compile once, serialize, run later.
pub const bytecode = @import("script/bytecode.zig");
// ThreadsafeFunction: call a pinned JS function from any thread. The driver delivers queued calls.
const tsfn_impl = @import("runtime/tsfn.zig");
pub const tsfn = struct {
    pub const TsfnHandle = tsfn_impl.TsfnHandle;
    pub const acquire = tsfn_impl.acquire;
    pub const call = tsfn_impl.call;
    pub const release = tsfn_impl.release;
};
// Runtime control: interrupt, execution time limit, GC, memory usage.
pub const runtime_control = @import("runtime/runtime_control.zig");
// Zero-copy ArrayBuffer / Uint8Array over a native-owned byte slice.
pub const buffers = @import("value/buffers.zig");
// CommonJS-style require() over the same ModuleLoader ABI as ES modules.
pub const cjs = @import("script/cjs.zig");
// Attach native finalizer callbacks to arbitrary JS objects.
pub const weakcb = @import("value/weakcb.zig");
// Host-side Symbol and Symbol.for. Unique symbols compare unequal; registry symbols match JS Symbol.for(key).
pub const symbol = @import("value/symbol.zig");
// Arbitrary-name host property trap (JSI HostObject shape).
pub const host_object = @import("value/host_object.zig");
// QuickJS-only embedding helpers used by consumers that host QuickJS directly.
pub const quickjs_host = if (backend_mod.isQuickJsApiBackend(backend_mod.active_backend)) @import("backend/quickjs/host.zig") else struct {};
/// Raw QuickJS C declarations for the selected QuickJS-family backend.
///
/// This is intentionally unavailable on JSC builds: `qjs` is an empty type there, so attempting to use a QuickJS declaration fails at compile time.
pub const qjs = if (backend_mod.isQuickJsApiBackend(backend_mod.active_backend))
    backend_mod.ActiveEngineModule.qjs
else
    struct {};
// Backend-agnostic callable host object support. Each backend file mirrors the public surface (HandleData / create / createWithMethods / setMethod / setStringProp / setIntProp / getOpaque / getClassId) so cross-backend consumer code can stay unchanged.
pub const native_handle = switch (backend_mod.active_backend) {
    .quickjs, .quickjs_ng => @import("value/native_handle.zig"),
    .jsc => @import("backend/jsc/native_handle.zig"),
    .escargot => @import("backend/escargot/native_handle.zig"),
    .hermes => @import("backend/hermes/native_handle.zig"),
};
// Chrome DevTools Protocol inspector: start/stop an attach-ready debugger endpoint glued to the transport + console tap machinery.
pub const inspector = @import("inspector/root.zig");
// JSC-only: expose JavaScriptCore's built-in WebKit Inspector so Safari's Develop menu can attach with full breakpoint/stepping. Under QJS this is a struct{} placeholder — the parallel CDP inspector above handles QJS.
pub const jsc_remote_inspector = if (backend_mod.active_backend == .jsc)
    @import("backend/jsc/remote_inspector.zig")
else
    struct {};
// Block the JS thread until a JS Promise settles, pumping microtasks + timers.
pub const async_bridge = @import("runtime/async_bridge.zig");
/// Stable Zig access to the installed typed C ABI.  Keep implementation-only helpers in c_api.zig private to the package: importing this module must not expose test-only string-evaluation or fault-injection helpers.
pub const c_api = struct {
    pub const Utf8 = c_api_impl.Utf8;
    pub const Bytes = c_api_impl.Bytes;
    pub const EvalOptions = c_api_impl.EvalOptions;
    pub const Callback = @import("abi/api_bind.zig").Callback;
    pub const Finalize = @import("abi/api_bind.zig").Finalize;
    pub const NativeSyncStart = c_api_impl.NativeSyncStart;
    pub const LoopTask = c_api_impl.LoopTask;
    pub const LoopSchedule = c_api_impl.LoopSchedule;
    pub const LoopCancel = c_api_impl.LoopCancel;
    pub const LogHandler = @import("types.zig").LogHandler;

    pub const js_bay_engine_create = c_api_impl.js_bay_engine_create;
    pub const js_bay_engine_create2 = c_api_impl.js_bay_engine_create2;
    pub const js_bay_engine_destroy = c_api_impl.js_bay_engine_destroy;
    pub const js_bay_engine_request_interrupt = c_api_impl.js_bay_engine_request_interrupt;
    pub const js_bay_engine_clear_interrupt = c_api_impl.js_bay_engine_clear_interrupt;
    pub const js_bay_engine_set_execution_time_limit = c_api_impl.js_bay_engine_set_execution_time_limit;
    pub const js_bay_engine_set_memory_limit = c_api_impl.js_bay_engine_set_memory_limit;
    pub const js_bay_engine_evaluate = c_api_impl.js_bay_engine_evaluate;
    pub const js_bay_engine_global = c_api_impl.js_bay_engine_global;
    pub const js_bay_engine_bind = c_api_impl.js_bay_engine_bind;
    pub const js_bay_engine_bind_sync = c_api_impl.js_bay_engine_bind_sync;
    pub const js_bay_sync_complete = c_api_impl.js_bay_sync_complete;
    pub const js_bay_engine_attach_loop = c_api_impl.js_bay_engine_attach_loop;
    pub const js_bay_engine_detach_loop = c_api_impl.js_bay_engine_detach_loop;
    pub const js_bay_engine_loop_status = c_api_impl.js_bay_engine_loop_status;
    pub const js_bay_engine_run_loop = c_api_impl.js_bay_engine_run_loop;
    pub const js_bay_engine_stop_loop = c_api_impl.js_bay_engine_stop_loop;
    pub const js_bay_engine_inspector_start = c_api_impl.js_bay_engine_inspector_start;
    pub const js_bay_engine_inspector_stop = c_api_impl.js_bay_engine_inspector_stop;
    pub const js_bay_engine_compile_bytecode = c_api_impl.js_bay_engine_compile_bytecode;
    pub const js_bay_engine_run_bytecode = c_api_impl.js_bay_engine_run_bytecode;

    pub const js_bay_value_retain = c_api_impl.js_bay_value_retain;
    pub const js_bay_value_release = c_api_impl.js_bay_value_release;
    pub const js_bay_value_undefined = c_api_impl.js_bay_value_undefined;
    pub const js_bay_value_null = c_api_impl.js_bay_value_null;
    pub const js_bay_value_new_bool = c_api_impl.js_bay_value_new_bool;
    pub const js_bay_value_new_number = c_api_impl.js_bay_value_new_number;
    pub const js_bay_value_new_string = c_api_impl.js_bay_value_new_string;
    pub const js_bay_value_new_array_buffer = c_api_impl.js_bay_value_new_array_buffer;
    pub const js_bay_value_new_json = c_api_impl.js_bay_value_new_json;
    pub const js_bay_value_new_error = c_api_impl.js_bay_value_new_error;
    pub const js_bay_value_new_object = c_api_impl.js_bay_value_new_object;
    pub const js_bay_value_new_array = c_api_impl.js_bay_value_new_array;
    pub const js_bay_value_type = c_api_impl.js_bay_value_type;
    pub const js_bay_value_to_bool = c_api_impl.js_bay_value_to_bool;
    pub const js_bay_value_to_number = c_api_impl.js_bay_value_to_number;
    pub const js_bay_value_to_utf8 = c_api_impl.js_bay_value_to_utf8;
    pub const js_bay_value_to_json = c_api_impl.js_bay_value_to_json;
    pub const js_bay_value_copy_buffer = c_api_impl.js_bay_value_copy_buffer;
    pub const js_bay_value_get = c_api_impl.js_bay_value_get;
    pub const js_bay_value_set = c_api_impl.js_bay_value_set;
    pub const js_bay_value_call = c_api_impl.js_bay_value_call;
    pub const js_bay_value_construct = c_api_impl.js_bay_value_construct;
    pub const js_bay_value_has = c_api_impl.js_bay_value_has;
    pub const js_bay_value_delete = c_api_impl.js_bay_value_delete;
    pub const js_bay_value_keys = c_api_impl.js_bay_value_keys;
    pub const js_bay_value_instance_of = c_api_impl.js_bay_value_instance_of;
    pub const js_bay_free_bytes = c_api_impl.js_bay_free_bytes;
};

// Force export C API symbols in static/shared library builds
comptime {
    _ = c_api_impl;
    // Keep create2 alive + force C export (library-only otherwise GC / omit it).
    @export(&c_api_impl.js_bay_engine_create2, .{ .name = "js_bay_engine_create2" });
}

// Pull in the test aggregator so `zig build test` discovers the suites under src/tests/.
comptime {
    if (@import("builtin").is_test) {
        _ = @import("tests/all_tests.zig");
    }
}
