//! Aggregator — imported from root.zig so that `zig build test` picks up all test files in src/tests/.
//! Spike backends (escargot/hermes) share the suite source; out-of-scope suites are not imported
//! (see docs/capability.md). In-scope: eval, value/object, Promise, buffers (basic), timers,
//! host_object, Escargot ESM, Hermes .hbc. Out: engine_thread / thick C ABI, inspector,
//! deep event-loop contracts, heap/interrupt, Escargot disk bytecode cache, advanced buffer
//! transfer/copy, resource/OOM/stack limits.

const backend = @import("../backend.zig");
const build_options = @import("build_options");

const spike = backend.isSpikeBackend(backend.active_backend);

comptime {
    if (spike) {
        _ = @import("spike_smoke_tests.zig");
        _ = @import("spike_adversarial_tests.zig");
    }
    _ = @import("public_module_tests.zig");
    _ = @import("../script/typed_eval.zig");
    _ = @import("test_helpers.zig");
    _ = @import("value_tests.zig");
    _ = @import("string_roundtrip_tests.zig");
    _ = @import("engine_tests.zig");
    // engine_thread: spike smoke already covers start/id/stop/post/wait; import full suite and
    // Skip only cases that need interrupt/heap/bind-sync not yet green on Escargot/Hermes.
    _ = @import("engine_thread_tests.zig");
    if (!spike) {
        _ = @import("self_driven_loop_tests.zig");
        _ = @import("internal_thread_safety_tests.zig");
        _ = @import("debugger_tests.zig");
    }
    if (!spike and build_options.inspector_transport) {
        _ = @import("debug_cold_contract_tests.zig");
    }
    if (!spike) {
        _ = @import("pristine_intrinsics_lifecycle_tests.zig");
    }
    // Native callbacks: Escargot OK; Hermes host-throw path uses in-engine throw (try both).
    _ = @import("native_function_tests.zig");
    if (!spike) {
        _ = @import("listeners_tests.zig");
        _ = @import("host_dispatch_tests.zig");
    }
    _ = @import("dispatch_queue_contract_tests.zig");
    if (!spike) {
        _ = @import("console_tests.zig");
    }
    _ = @import("console_format_tests.zig");
    if (backend.isQuickJsApiBackend(backend.active_backend)) {
        _ = @import("class_id_tests.zig");
        _ = @import("native_handle_handle_tests.zig");
        _ = @import("native_handle_lifecycle_tests.zig");
        _ = @import("native_handle_callback_store_tests.zig");
        _ = @import("native_handle_callback_store_owner_tests.zig");
    }
    if (!spike) {
        _ = @import("reference_tests.zig");
    }
    _ = @import("external_tests.zig");
    _ = @import("atoms_tests.zig");
    _ = @import("errors_tests.zig");
    _ = @import("bytecode_tests.zig");
    // Disk cache: Hermes .hbc + fingerprint store; Escargot has no bytecode blob — keep gated.
    if (build_options.bytecode_cache and (!spike or backend.isHermesBackend(backend.active_backend))) {
        _ = @import("cache_tests.zig");
    } else if (!spike) {
        _ = @import("cache_disabled_tests.zig");
    }
    if (!spike) {
        _ = @import("stack_tests.zig");
    }
    _ = @import("tsfn_tests.zig");
    _ = @import("promise_tests.zig");
    _ = @import("typedarray_tests.zig");
    // DataView is in spike scope (basic); covered alongside TypedArray.
    _ = @import("dataview_tests.zig");
    _ = @import("datetime_tests.zig");
    // Map/Set in scope; Hermes skips one early-stop foreach ABRT inside the suite.
    _ = @import("mapset_tests.zig");
    // ESM: Escargot ModuleLoader; Hermes skips inside modules_tests.
    _ = @import("modules_tests.zig");
    if (!spike) {
        _ = @import("c_api_tests.zig");
        _ = @import("borrowed_retain_tests.zig");
    }
    // object_ops: Escargot full; Hermes imported (trap/exception paths must not ABRT).
    if (!spike or backend.isEscargotBackend(backend.active_backend) or backend.isHermesBackend(backend.active_backend)) {
        _ = @import("object_ops_tests.zig");
    }
    if (!spike) {
        _ = @import("runtime_control_tests.zig");
    }
    // buffers_tests: basic + finalizer in spike scope; advanced cases Skip inside the suite.
    // Transfer: Escargot native; Hermes polyfill (detachArrayBuffer + copy). Tight-cap case still QJS-only Skip inside.
    _ = @import("buffers_tests.zig");
    _ = @import("buffers_transfer_tests.zig");
    _ = @import("cjs_tests.zig");
    _ = @import("weakcb_tests.zig");
    if (!spike) {
        _ = @import("reference_lifetime_tests.zig");
        _ = @import("value_contract_tests.zig");
    }
    _ = @import("buffer_contract_tests.zig");
    if (!spike) {
        _ = @import("exception_boundary_tests.zig");
    }
    _ = @import("microtask_order_tests.zig");
    _ = @import("promise_state_tests.zig");
    // Escargot: PromiseRejectCallback wired. Hermes/JSC: setRejectionTracker returns false (tests no-op).
    _ = @import("rejection_tracker_tests.zig");
    if (!spike) {
        _ = @import("engine_thread_guard_tests.zig");
        _ = @import("finalizer_contract_tests.zig");
    }
    _ = @import("host_object_tests.zig");
    _ = @import("promise_chain_tests.zig");
    // Core value contracts: spike-safe subset (callable/array/property/symbol).
    _ = @import("callable_contract_tests.zig");
    _ = @import("array_contract_tests.zig");
    _ = @import("property_contract_tests.zig");
    _ = @import("symbol_tests.zig");
    if (!spike) {
        _ = @import("scope_yield_tests.zig");
        _ = @import("idle_gc_tests.zig");
        _ = @import("oom_error_tests.zig");
        _ = @import("oom_sweep_tests.zig");
        _ = @import("inspector_host_transport_tests.zig");
    }
    if (!spike and build_options.inspector) {
        _ = @import("console_tap_tests.zig");
        _ = @import("inspector_host_contract_tests.zig");
    }
    if (!spike and build_options.inspector_transport) {
        _ = @import("inspector_tests.zig");
        if (build_options.inspector) {
            _ = @import("cdp_reference_tests.zig");
            _ = @import("cdp_properties_tests.zig");
            _ = @import("cdp_console_tests.zig");
            _ = @import("cdp_heap_async_tests.zig");
            _ = @import("async_job_oom_tests.zig");
            _ = @import("cdp_alignment_tests.zig");
            _ = @import("cdp_discovery_tests.zig");
            _ = @import("debugger_race_tests.zig");
            _ = @import("debugger_lifecycle_tests.zig");
            _ = @import("debugger_protocol_tests.zig");
            _ = @import("inspector_objects_tests.zig");
            if (backend.isJscApiBackend(backend.active_backend)) {
                _ = @import("jsc_async_wrapper_tests.zig");
            }
        }
        _ = @import("cdp_governance_contract_tests.zig");
        _ = @import("primjs_diagnostics_contract_tests.zig");
    }
    // bind_sync / syncTrampoline ride on spikeInstall — import on spike too.
    _ = @import("native_sync_tests.zig");
    if (!spike) {
        _ = @import("primjs_patch_semantics_tests.zig");
        _ = @import("async_bridge_tests.zig");
        _ = @import("resource_limit_tests.zig");
        _ = @import("host_wake_tests.zig");
        _ = @import("js_event_loop_contract_tests.zig");
    }
    _ = @import("browser_event_loop_tests.zig");
    _ = @import("jsc_microtask_contract_tests.zig");
    _ = @import("zev_notifications_tests.zig");
    _ = @import("timer_unification_tests.zig");
    _ = @import("timer_order_tests.zig");
    // timers_tests.zig uses raw QuickJS C callbacks — QJS backends only.
    if (backend.isQuickJsApiBackend(backend.active_backend)) {
        _ = @import("timers_tests.zig");
    }
    if (backend.isJscApiBackend(backend.active_backend)) {
        _ = @import("jsc_bigint_fallback_tests.zig");
        _ = @import("jsc_native_tests.zig");
        _ = @import("jsc_remote_inspector_tests.zig");
        _ = @import("jsc_timer_tests.zig");
    }
    if (!spike and build_options.stress_tests) {
        _ = @import("event_loop_stress_tests.zig");
        if (backend.isQuickJsApiBackend(backend.active_backend)) {
            _ = @import("timers_stress_tests.zig");
        }
    }
    _ = @import("jsc_sentinel_tests.zig");
    _ = @import("jsc_typed_text_oom_tests.zig");
    _ = @import("jsc_copy_buffer_tests.zig");
    // C copyBuffer contract: Escargot/Hermes have getArrayBufferSlice + transfer; exercise on spike too.
    _ = @import("buffer_copy_contract_tests.zig");
    if (!spike) {
        _ = @import("proxy_array_identity_tests.zig");
        _ = @import("reference_stress_tests.zig");
    }
}
