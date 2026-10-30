//! Contracts for the zero-debug collection path.
//!
//! These assert externally meaningful debugger state after ordinary engine use, rather than timing a particular machine. The implementation must keep the collection machinery cold until a debugger session explicitly enables it.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const async_stack = @import("../inspector/async_stack.zig");
const cold_probe = @import("debug_cold_probe.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const dispatch = @import("../runtime/dispatch.zig");
const io = @import("../platform/io.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const inspector = @import("../inspector/root.zig");
const inspector_state = @import("../inspector/root.zig").state;
const instance_map = @import("../runtime/instance_map.zig");
const value = @import("../value/root.zig");
const wire = @import("inspector_tests.zig");

fn sendCdpAndPump(id: i32, stream: wire.TestStream, reader: *wire.FrameReader, received: *std.ArrayList(u8), message: []const u8, response_id: i64) !void {
    const start = received.items.len;
    try wire.writeMaskedText(stream, message);
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        _ = dispatch.tickInstance(id);
        engine.runEventLoopOnce(id);
        try wire.readTextFrames(testing.allocator, reader, received, 1);
        if (try wire.hasResponseIdSince(testing.allocator, received.items, start, response_id)) return;
    }
    return error.TestUnexpectedResult;
}
/// A socket close is observed by the transport reader thread.  Keep pumping the engine owner until its queued session-cleanup task applies the new aggregate async-depth request.
fn pumpUntilAsyncDepth(id: i32, expected: u32) !void {
    // Transport reader observes the socket close on another thread; give it wall time on loaded CI hosts.
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        _ = dispatch.tickInstance(id);
        engine.runEventLoopOnce(id);
        if (async_stack.depth(id) == expected) return;
        io.sleepMs(1);
    }
    return error.TestUnexpectedResult;
}

/// Apply a CDP owner task without draining Promise jobs that were deliberately queued before the request.  This exposes the cold-to-hot queue boundary.
fn sendCdpWithoutDrainingJobs(id: i32, stream: wire.TestStream, reader: *wire.FrameReader, received: *std.ArrayList(u8), message: []const u8, response_id: i64) !void {
    const start = received.items.len;
    try wire.writeMaskedText(stream, message);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        _ = dispatch.tickInstance(id);
        try wire.readTextFrames(testing.allocator, reader, received, 1);
        if (try wire.hasResponseIdSince(testing.allocator, received.items, start, response_id)) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn consoleEventForToken(payloads: []const u8, token: []const u8) ?[]const u8 {
    const event_start = std.mem.lastIndexOf(u8, payloads[0..(std.mem.indexOf(u8, payloads, token) orelse return null)], "{\"method\":\"Runtime.consoleAPICalled\"") orelse return null;
    const event_end = std.mem.indexOfPos(u8, payloads, event_start, "}}}") orelse return null;
    return payloads[event_start .. event_end + 3];
}

fn queueQuickJsJobWithoutDrain(id: i32, source: [:0]const u8) !void {
    const ctx = engine.getContext(id) orelse return error.MissingContext;
    switch (backend.active_backend) {
        .quickjs => {
            const c = @import("../backend/quickjs/c_api.zig");
            const result = c.qjs.JS_Eval(ctx, source.ptr, source.len, "cold-to-hot.js", c.qjs.JS_EVAL_TYPE_GLOBAL);
            defer c.jsbay_qjs_JS_FreeValue(ctx, result);
            try testing.expect(!c.jsIsException(result));
        },
        .quickjs_ng => {
            const c = @import("../backend/quickjs_ng/c_api.zig");
            const result = c.qjs.JS_Eval(ctx, source.ptr, source.len, "cold-to-hot.js", c.qjs.JS_EVAL_TYPE_GLOBAL);
            defer c.jsbay_qjs_JS_FreeValue(ctx, result);
            try testing.expect(!c.jsIsException(result));
        },
        .jsc => unreachable,
    }
}

fn drainPromiseJobsAtTaskBoundary(id: i32) !void {
    const ctx = engine.getContext(id) orelse return error.MissingContext;
    @import("../runtime/js_scheduler.zig").checkpoint(id, ctx);
}

/// Runs from Promise job A while the native hook has entered phase 1.  The depth transition drops B's prior queue entry but retains the C hook until A's phase 2, then A queues fresh job C.
fn flipAsyncDepthDuringPromiseJob(id: i32, _: value.NativeArgs) value.NativeResult {
    const instance = instance_map.getInstance(id) orelse return .undefined_val;
    switch (backend.active_backend) {
        .quickjs => {
            const jobs = @import("../backend/quickjs/jobs.zig");
            jobs.setAsyncStackDepth(instance.monoRuntime().?, id, 0);
            jobs.setAsyncStackDepth(instance.monoRuntime().?, id, 1);
        },
        .quickjs_ng => {
            const jobs = @import("../backend/quickjs_ng/jobs.zig");
            jobs.setAsyncStackDepth(instance.monoRuntime().?, id, 0);
            jobs.setAsyncStackDepth(instance.monoRuntime().?, id, 1);
        },
        .jsc => unreachable,
    }
    return .undefined_val;
}

var cold_window_enqueue_failed = false;

/// While job A is active, leave depth at zero just long enough to enqueue B. A's cached callback still receives phase 2, but B must not be marked.
fn queueDuringZeroDepthWindow(id: i32, _: value.NativeArgs) value.NativeResult {
    const instance = instance_map.getInstance(id) orelse return .undefined_val;
    switch (backend.active_backend) {
        .quickjs => @import("../backend/quickjs/jobs.zig").setAsyncStackDepth(instance.monoRuntime().?, id, 0),
        .quickjs_ng => @import("../backend/quickjs_ng/jobs.zig").setAsyncStackDepth(instance.monoRuntime().?, id, 0),
        .jsc => unreachable,
    }
    queueQuickJsJobWithoutDrain(id, "Promise.resolve().then(function p2ColdB(){ console.log('p2-cold-b-token'); });") catch {
        cold_window_enqueue_failed = true;
    };
    switch (backend.active_backend) {
        .quickjs => @import("../backend/quickjs/jobs.zig").setAsyncStackDepth(instance.monoRuntime().?, id, 1),
        .quickjs_ng => @import("../backend/quickjs_ng/jobs.zig").setAsyncStackDepth(instance.monoRuntime().?, id, 1),
        .jsc => unreachable,
    }
    return .undefined_val;
}

test "debug cold: NG ordinary engine evaluation keeps source collection and location hooks inactive" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const evaluated = engine.evalScript(id, "globalThis.coldContract = 1;", "cold-contract-before-start.js");
    defer helpers.freeEvalResult(evaluated);
    try testing.expect(evaluated.err == null);

    // A normal host evaluation must not retain source or arm an interpreter location callback merely because the binary contains Inspector support.
    try testing.expectEqual(@as(u32, 0), debugger_mod.scriptIdForUrl(id, "cold-contract-before-start.js"));
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(id));
}

const InspectorDisabledTests = if (!@import("build_options").inspector) struct {
    test "debug cold: disabled Inspector start rejects without state or listener" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        try testing.expectError(error.UnsupportedFeature, inspector.start(id, .{ .port = 0, .target_id = "disabled-inspector" }));
        try testing.expect(inspector_state.stateByInstance(id) == null);
        try testing.expectEqual(@as(usize, 0), inspector.liveConsoleEntries());
    }
};

comptime {
    _ = InspectorDisabledTests;
}

const InspectorEnabledTests = if (@import("build_options").inspector) struct {
    test "debug cold: NG started Inspector without a client still does not collect scripts or arm locations" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{});
        defer inspector.stop(handle);

        const evaluated = engine.evalScript(id, "globalThis.coldServerContract = 1;", "cold-contract-no-client.js");
        defer helpers.freeEvalResult(evaluated);
        try testing.expect(evaluated.err == null);

        // Listening is not equivalent to an attached DevTools debugger. Until a client enables Debugger, it must have neither a source history nor an active per-location interpreter callback.
        try testing.expectEqual(@as(u32, 0), debugger_mod.scriptIdForUrl(id, "cold-contract-no-client.js"));
        try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(id));
    }

    test "debug cold: Inspector listener without Runtime.enable does not copy console stacks" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
        if (comptime !@import("build_options").inspector) return;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{});
        defer inspector.stop(handle);
        cold_probe.resetDebugStackCopies();
        const evaluated = engine.evalScript(id, "console.log('cold listener');", "cold-listener-console.js");
        defer helpers.freeEvalResult(evaluated);
        try testing.expect(evaluated.err == null);
        try testing.expectEqual(@as(usize, 0), cold_probe.debugStackCopies());
    }
};

comptime {
    _ = InspectorEnabledTests;
}

test "debug cold: JSC leaves Promise and debug helper globals untouched before a debugging session" {
    if (comptime backend.active_backend != .jsc) return;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    // These globals would show that application-visible intrinsics changed before any debugging session existed.
    try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncDepth'))", "false");
    try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsBindAsync'))", "false");
    try helpers.expectEvalEquals(id, "String(Promise.prototype.then).includes('[native code]')", "true");
}

const InspectorEnabledTests2 = if (@import("build_options").inspector) struct {
    test "debug cold: JSC async wrappers follow CDP depth and preserve application replacements" {
        if (comptime backend.active_backend != .jsc) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "jsc-async-wrapper-lifecycle" });
        var inspector_stopped = false;
        defer if (!inspector_stopped) inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "jsc-async-wrapper-lifecycle");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try helpers.evalOk(id, "globalThis.__jscThenBefore = Promise.prototype.then; globalThis.__jscMicroBefore = queueMicrotask;");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        try helpers.expectEvalEquals(id, "String(Promise.prototype.then !== globalThis.__jscThenBefore && queueMicrotask !== globalThis.__jscMicroBefore)", "true");

        // A page may replace these intrinsics while debugging. Teardown owns only the wrapper it installed and must leave that replacement intact.
        try helpers.evalOk(id, "globalThis.__jscAppThen = function(a,b){ return globalThis.__jscThenBefore.call(this,a,b); }; globalThis.__jscAppMicro = function(fn){ return globalThis.__jscMicroBefore(fn); }; Promise.prototype.then = globalThis.__jscAppThen; globalThis.queueMicrotask = globalThis.__jscAppMicro;");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":0}}", 2);
        try helpers.expectEvalEquals(id, "String(Promise.prototype.then === globalThis.__jscAppThen && queueMicrotask === globalThis.__jscAppMicro)", "true");
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncDepth') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsBindAsync') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncState'))", "false");

        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":3,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 3);
        try helpers.expectEvalEquals(id, "String(Promise.prototype.then !== globalThis.__jscAppThen && queueMicrotask !== globalThis.__jscAppMicro)", "true");
        inspector.stop(handle);
        inspector_stopped = true;
        try helpers.expectEvalEquals(id, "String(Promise.prototype.then === globalThis.__jscAppThen && queueMicrotask === globalThis.__jscAppMicro)", "true");
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncDepth') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsBindAsync') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncState'))", "false");
    }

    test "debug cold: JSC async wrapper restores a missing queueMicrotask property" {
        if (comptime backend.active_backend != .jsc) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "jsc-async-missing-microtask" });
        var inspector_stopped = false;
        defer if (!inspector_stopped) inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "jsc-async-missing-microtask");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try helpers.evalOk(id, "delete globalThis.queueMicrotask;");
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, 'queueMicrotask'))", "false");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        try helpers.expectEvalEquals(id, "typeof queueMicrotask", "function");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":0}}", 2);
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, 'queueMicrotask'))", "false");

        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":3,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 3);
        try helpers.expectEvalEquals(id, "typeof queueMicrotask", "function");
        inspector.stop(handle);
        inspector_stopped = true;
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, 'queueMicrotask'))", "false");
    }

    test "debug cold: JSC async wrapper restores a non-function queueMicrotask value" {
        if (comptime backend.active_backend != .jsc) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "jsc-async-nonfunction-microtask" });
        var inspector_stopped = false;
        defer if (!inspector_stopped) inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "jsc-async-nonfunction-microtask");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try helpers.evalOk(id, "globalThis.queueMicrotask = 42;");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        try helpers.expectEvalEquals(id, "typeof queueMicrotask", "function");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":0}}", 2);
        try helpers.expectEvalEquals(id, "String(queueMicrotask)", "42");

        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":3,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 3);
        try helpers.expectEvalEquals(id, "typeof queueMicrotask", "function");
        inspector.stop(handle);
        inspector_stopped = true;
        try helpers.expectEvalEquals(id, "String(queueMicrotask)", "42");
    }

    test "debug cold: JSC async teardown survives a deleted Promise global" {
        if (comptime backend.active_backend != .jsc) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "jsc-async-deleted-promise" });
        defer inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "jsc-async-deleted-promise");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try helpers.evalOk(id, "globalThis.__jscMicroBeforePromiseDelete = queueMicrotask;");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        try helpers.evalOk(id, "delete globalThis.Promise;");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":0}}", 2);
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, 'Promise'))", "false");
        try helpers.expectEvalEquals(id, "String(queueMicrotask === globalThis.__jscMicroBeforePromiseDelete)", "true");
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncDepth') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsBindAsync') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncState'))", "false");

        // Teardown must also tolerate an application replacing the global with an object that has no prototype, and preserve its queue replacement.
        try helpers.evalOk(id, "globalThis.__jscAppPromise = { marker: 42 }; globalThis.__jscAppMicroAfterPromiseDelete = function() {}; globalThis.Promise = globalThis.__jscAppPromise; globalThis.queueMicrotask = globalThis.__jscAppMicroAfterPromiseDelete;");
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":3,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 3);
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":4,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":0}}", 4);
        try helpers.expectEvalEquals(id, "String(Promise === globalThis.__jscAppPromise && queueMicrotask === globalThis.__jscAppMicroAfterPromiseDelete)", "true");
        try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncDepth') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsBindAsync') || Object.prototype.hasOwnProperty.call(globalThis, '__jsbay_qjsAsyncState'))", "false");
    }
};

comptime {
    _ = InspectorEnabledTests2;
}

test "debug cold: console without an Inspector tap does not copy a native debug stack" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    cold_probe.resetDebugStackCopies();

    const evaluated = engine.evalScript(id, "console.log('cold console contract');", "cold-console-contract.js");
    defer helpers.freeEvalResult(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expectEqual(@as(usize, 0), cold_probe.debugStackCopies());
}

test "debug cold: QuickJS depth zero does not retain a debugger job queue" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(!async_stack.hasJobQueueForTesting(id));

    const evaluated = engine.evalScript(id, "Promise.resolve(1).then(function() {});", "cold-job-contract.js");
    defer helpers.freeEvalResult(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expect(!async_stack.hasJobQueueForTesting(id));
}

const InspectorEnabledTests3 = if (@import("build_options").inspector) struct {
    test "debug cold: QuickJS Promise jobs skip the debug hook until async stacks are requested" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        try testing.expect(!async_stack.hasSlotForTesting(id));

        // The listener alone must not leave a native job callback on every Promise/microtask. A queue-retention assertion cannot see this work.
        cold_probe.resetJobHookCallbacks();
        const ordinary = engine.evalScript(id, "Promise.resolve().then(function() {});", "cold-job-ordinary.js");
        defer helpers.freeEvalResult(ordinary);
        try testing.expect(ordinary.err == null);
        try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());

        const handle = try inspector.start(id, .{ .port = 0, .target_id = "cold-job-hook" });
        var inspector_stopped = false;
        defer if (!inspector_stopped) inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "cold-job-hook");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);
        cold_probe.resetJobHookCallbacks();
        const listening = engine.evalScript(id, "Promise.resolve().then(function() {});", "cold-job-listener.js");
        defer helpers.freeEvalResult(listening);
        try testing.expect(listening.err == null);
        try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());

        // The transport thread must queue this change; its response is emitted only after the JS owner installs the native callback.
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        cold_probe.resetJobHookCallbacks();
        const enabled = engine.evalScript(id, "Promise.resolve().then(function() {});", "warm-job-hook.js");
        defer helpers.freeEvalResult(enabled);
        try testing.expect(enabled.err == null);
        try testing.expect(cold_probe.jobHookCallbacks() != 0);

        // Turning the depth off restores the cold cost contract before Inspector finalization, and stop keeps it cold after teardown.
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":0}}", 2);
        cold_probe.resetJobHookCallbacks();
        const disabled = engine.evalScript(id, "Promise.resolve().then(function() {});", "disabled-job-hook.js");
        defer helpers.freeEvalResult(disabled);
        try testing.expect(disabled.err == null);
        try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());

        inspector.stop(handle);
        inspector_stopped = true;
        try testing.expect(!async_stack.hasSlotForTesting(id));
        cold_probe.resetJobHookCallbacks();
        const stopped = engine.evalScript(id, "Promise.resolve().then(function() {});", "stopped-job-hook.js");
        defer helpers.freeEvalResult(stopped);
        try testing.expect(stopped.err == null);
        try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());

        // A later listener is still cold until a new client asks for async stacks. This catches stale native hook state surviving stop/restart.
        const restarted_handle = try inspector.start(id, .{});
        defer inspector.stop(restarted_handle);
        cold_probe.resetJobHookCallbacks();
        const restarted = engine.evalScript(id, "Promise.resolve().then(function() {});", "restarted-job-hook.js");
        defer helpers.freeEvalResult(restarted);
        try testing.expect(restarted.err == null);
        try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());
    }

    test "debug cold: explicit debugger activation collects only future scripts and detaching cools it again" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const before = engine.evalScript(id, "globalThis.coldOldClosure = function() { return 17; };", "cold-old-closure.js");
        defer helpers.freeEvalResult(before);
        try testing.expect(before.err == null);

        const runtime = instance_map.getInstance(id) orelse return error.MissingInstance;
        _ = debugger_mod.attach(id, @ptrCast(runtime.monoRuntime().?));
        try testing.expect(debugger_mod.handlerInstallThreadId(id) != 0);

        // Executing a closure compiled while cold must not assign its URL a debugger source identity after debugging is enabled.
        const invoked = engine.evalScript(id, "coldOldClosure();", "cold-closure-driver.js");
        defer helpers.freeEvalResult(invoked);
        try testing.expect(invoked.err == null);
        try testing.expectEqual(@as(u32, 0), debugger_mod.scriptIdForUrl(id, "cold-old-closure.js"));

        const future = engine.evalScript(id, "globalThis.coldFutureScript = 18;", "cold-future-script.js");
        defer helpers.freeEvalResult(future);
        try testing.expect(future.err == null);
        try testing.expect(debugger_mod.scriptIdForUrl(id, "cold-future-script.js") != 0);

        debugger_mod.detach(id);
        try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(id));
        const after = engine.evalScript(id, "globalThis.coldAfterStop = 19;", "cold-after-stop.js");
        defer helpers.freeEvalResult(after);
        try testing.expect(after.err == null);
        try testing.expectEqual(@as(u32, 0), debugger_mod.scriptIdForUrl(id, "cold-after-stop.js"));
    }

    test "debug cold: Debugger.disable releases a session's async stack request" {
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "async-depth-disable" });
        defer inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "async-depth-disable");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        try testing.expectEqual(@as(u32, 1), async_stack.depth(id));
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.disable\"}", 2);
        try testing.expectEqual(@as(u32, 0), async_stack.depth(id));

        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            cold_probe.resetJobHookCallbacks();
            const evaluated = engine.evalScript(id, "Promise.resolve().then(function() {});", "disabled-session-job.js");
            defer helpers.freeEvalResult(evaluated);
            try testing.expect(evaluated.err == null);
            try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());
        }
    }

    test "debug cold: async stack depth belongs to live debugger sessions" {
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "async-depth-disconnect" });
        defer inspector.stop(handle);

        const first = try wire.connect(inspector.boundPort(handle));
        var first_open = true;
        defer if (first_open) first.close();
        try wire.doWsHandshake(testing.allocator, first, "async-depth-disconnect");
        var first_reader = wire.FrameReader.init(first);
        defer first_reader.deinit(testing.allocator);
        var first_received: std.ArrayList(u8) = .empty;
        defer first_received.deinit(testing.allocator);

        const second = try wire.connect(inspector.boundPort(handle));
        var second_open = true;
        defer if (second_open) second.close();
        try wire.doWsHandshake(testing.allocator, second, "async-depth-disconnect");
        var second_reader = wire.FrameReader.init(second);
        defer second_reader.deinit(testing.allocator);
        var second_received: std.ArrayList(u8) = .empty;
        defer second_received.deinit(testing.allocator);

        if (comptime backend.active_backend == .jsc) {
            try helpers.evalOk(id, "globalThis.__thenBeforeSessionClose = Promise.prototype.then;");
        }

        try sendCdpAndPump(id, first, &first_reader, &first_received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        try sendCdpAndPump(id, second, &second_reader, &second_received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 2);
        try testing.expectEqual(@as(u32, 1), async_stack.depth(id));

        // Closing A must withdraw only A's request; B still needs parent stacks.
        first.close();
        first_open = false;
        try pumpUntilAsyncDepth(id, 1);
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            cold_probe.resetJobHookCallbacks();
            const active = engine.evalScript(id, "Promise.resolve().then(function() {});", "other-session-job.js");
            defer helpers.freeEvalResult(active);
            try testing.expect(active.err == null);
            try testing.expect(cold_probe.jobHookCallbacks() != 0);
        }

        // Once B disconnects there is no CDP owner for async parents.  This must remove the native QuickJS hook and restore JSC's visible Promise method.
        second.close();
        second_open = false;
        try pumpUntilAsyncDepth(id, 0);
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            cold_probe.resetJobHookCallbacks();
            const inactive = engine.evalScript(id, "Promise.resolve().then(function() {});", "last-session-job.js");
            defer helpers.freeEvalResult(inactive);
            try testing.expect(inactive.err == null);
            try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());
        }
        if (comptime backend.active_backend == .jsc) {
            try helpers.expectEvalEquals(id, "String(Promise.prototype.then === globalThis.__thenBeforeSessionClose)", "true");
        }
    }

    test "debug cold: owner eval reconciles a disconnected last async-stack session without a tick" {
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "async-depth-close-owner-eval" });
        defer inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        var stream_open = true;
        defer if (stream_open) stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "async-depth-close-owner-eval");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        if (comptime backend.active_backend == .jsc) {
            try helpers.evalOk(id, "globalThis.__closeOwnerThen = Promise.prototype.then;");
        }
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 1);
        try testing.expectEqual(@as(u32, 1), async_stack.depth(id));
        // Simulate the transport thread failing to allocate/post its cleanup task. The retained state bit must still be consumed by owner admission.
        inspector.testFailAllocationOnce(id, .async_depth_reconcile_post);
        stream.close();
        stream_open = false;

        // The transport callback is the synchronization boundary: after it has removed the session, deliberately do not tick before this host eval.
        const state = inspector_state.stateByInstance(id) orelse return error.MissingInspector;
        var attempts: usize = 0;
        while (inspector_state.sessionCount(state) != 0 and attempts < 10_000) : (attempts += 1) {
            std.Thread.yield() catch {};
        }
        try testing.expectEqual(@as(usize, 0), inspector_state.sessionCount(state));

        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) cold_probe.resetJobHookCallbacks();
        const evaluated = engine.evalScript(id, "Promise.resolve().then(function() {});", "close-owner-eval-job.js");
        defer helpers.freeEvalResult(evaluated);
        try testing.expect(evaluated.err == null);
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            try testing.expectEqual(@as(usize, 0), cold_probe.jobHookCallbacks());
        }
        try testing.expectEqual(@as(u32, 0), async_stack.depth(id));
        if (comptime backend.active_backend == .jsc) {
            try helpers.expectEvalEquals(id, "String(Promise.prototype.then === globalThis.__closeOwnerThen)", "true");
        }
    }

    test "debug cold: Promise jobs queued before async depth is enabled keep no later parent" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "cold-to-hot-promise-jobs" });
        defer inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "cold-to-hot-promise-jobs");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Runtime.enable\"}", 1);
        try queueQuickJsJobWithoutDrain(id, "Promise.resolve().then(function coldJob(){ console.log('cold-job-token'); });");

        // Do not use sendCdpAndPump here: it would drain coldJob before depth 1 takes effect and miss the FIFO hand-off between untraced and traced jobs.
        try sendCdpWithoutDrainingJobs(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 2);
        try queueQuickJsJobWithoutDrain(id, "function hotSchedule(){ Promise.resolve().then(function hotJob(){ console.log('hot-job-token'); }); } hotSchedule();");
        try drainPromiseJobsAtTaskBoundary(id);

        var attempts: usize = 0;
        while (attempts < 40) : (attempts += 1) {
            engine.runEventLoopOnce(id);
            try wire.readTextFrames(testing.allocator, &reader, &received, 1);
            if (std.mem.indexOf(u8, received.items, "cold-job-token") != null and std.mem.indexOf(u8, received.items, "hot-job-token") != null) break;
        }
        const cold_event = consoleEventForToken(received.items, "cold-job-token") orelse return error.TestUnexpectedResult;
        const hot_event = consoleEventForToken(received.items, "hot-job-token") orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.indexOf(u8, cold_event, "\"description\":\"Promise\"") == null);
        try testing.expect(std.mem.indexOf(u8, cold_event, "hotSchedule") == null);
        try testing.expect(std.mem.indexOf(u8, hot_event, "\"description\":\"Promise\"") != null);
        try testing.expect(std.mem.indexOf(u8, hot_event, "hotSchedule") != null);
    }

    test "debug cold: active callback depth flip does not give B C's Promise parent" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
        if (comptime !@import("build_options").inspector) return;

        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        value.registerFunction(id, null, "__flipAsyncDepthDuringJob", &flipAsyncDepthDuringPromiseJob);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "active-job-depth-flip" });
        defer inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "active-job-depth-flip");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Runtime.enable\"}", 1);
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 2);
        try queueQuickJsJobWithoutDrain(id,
            \\Promise.resolve().then(function p2A(){
            \\  __flipAsyncDepthDuringJob();
            \\  Promise.resolve().then(function p2C(){ console.log('p2-c-token'); });
            \\});
            \\Promise.resolve().then(function p2B(){ console.log('p2-b-token'); });
        );
        try drainPromiseJobsAtTaskBoundary(id);

        var attempts: usize = 0;
        while (attempts < 40) : (attempts += 1) {
            engine.runEventLoopOnce(id);
            try wire.readTextFrames(testing.allocator, &reader, &received, 1);
            if (std.mem.indexOf(u8, received.items, "p2-b-token") != null and std.mem.indexOf(u8, received.items, "p2-c-token") != null) break;
        }
        const b_event = consoleEventForToken(received.items, "p2-b-token") orelse return error.TestUnexpectedResult;
        const c_event = consoleEventForToken(received.items, "p2-c-token") orelse return error.TestUnexpectedResult;
        // B was scheduled before A entered and must never consume C's trace. C was scheduled by p2A after the transition, so only C has that parent.
        try testing.expect(std.mem.indexOf(u8, b_event, "p2A") == null);
        try testing.expect(std.mem.indexOf(u8, c_event, "p2A") != null);
    }

    test "debug cold: depth-zero window job does not inherit the later Promise parent" {
        if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
        if (comptime !@import("build_options").inspector) return;

        cold_window_enqueue_failed = false;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        value.registerFunction(id, null, "__queueDuringZeroDepthWindow", &queueDuringZeroDepthWindow);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "depth-zero-window-job" });
        defer inspector.stop(handle);
        const stream = try wire.connect(inspector.boundPort(handle));
        defer stream.close();
        try wire.doWsHandshake(testing.allocator, stream, "depth-zero-window-job");
        var reader = wire.FrameReader.init(stream);
        defer reader.deinit(testing.allocator);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(testing.allocator);

        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":1,\"method\":\"Runtime.enable\"}", 1);
        try sendCdpAndPump(id, stream, &reader, &received, "{\"id\":2,\"method\":\"Debugger.setAsyncCallStackDepth\",\"params\":{\"maxDepth\":1}}", 2);
        try queueQuickJsJobWithoutDrain(id,
            \\Promise.resolve().then(function p2WindowA(){
            \\  __queueDuringZeroDepthWindow();
            \\  Promise.resolve().then(function p2WindowC(){ console.log('p2-window-c-token'); });
            \\});
        );
        try drainPromiseJobsAtTaskBoundary(id);

        var attempts: usize = 0;
        while (attempts < 40) : (attempts += 1) {
            engine.runEventLoopOnce(id);
            try wire.readTextFrames(testing.allocator, &reader, &received, 1);
            if (std.mem.indexOf(u8, received.items, "p2-cold-b-token") != null and std.mem.indexOf(u8, received.items, "p2-window-c-token") != null) break;
        }
        try testing.expect(!cold_window_enqueue_failed);
        const b_event = consoleEventForToken(received.items, "p2-cold-b-token") orelse return error.TestUnexpectedResult;
        const c_event = consoleEventForToken(received.items, "p2-window-c-token") orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.indexOf(u8, b_event, "p2WindowA") == null);
        try testing.expect(std.mem.indexOf(u8, c_event, "p2WindowA") != null);
    }
};

comptime {
    _ = InspectorEnabledTests3;
}
