//! QuickJS line breakpoints. The eval runs on another thread because the location hook blocks the thread that is executing the script.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");
const io = @import("../platform/io.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const value = @import("../value/root.zig");
const helpers = @import("test_helpers.zig");

const HookRaceState = struct {
    stop: std.atomic.Value(bool) = .init(false),
    updates: std.atomic.Value(usize) = .init(0),
    pause_calls: std.atomic.Value(usize) = .init(0),
    script_calls: std.atomic.Value(usize) = .init(0),
};

fn countPauseA(_: i32, _: debugger_mod.PauseInfo) void {
    if (active_hook_test) |state| _ = state.pause_calls.fetchAdd(1, .seq_cst);
}

fn countPauseB(_: i32, _: debugger_mod.PauseInfo) void {
    if (active_hook_test) |state| _ = state.pause_calls.fetchAdd(1, .seq_cst);
}

fn countScriptA(_: i32, _: debugger_mod.ScriptInfo) void {
    if (active_hook_test) |state| _ = state.script_calls.fetchAdd(1, .seq_cst);
}

fn countScriptB(_: i32, _: debugger_mod.ScriptInfo) void {
    if (active_hook_test) |state| _ = state.script_calls.fetchAdd(1, .seq_cst);
}

var active_hook_test: ?*HookRaceState = null;

const ReentrantScriptHook = struct {
    id: i32,
    calls: std.atomic.Value(usize) = .init(0),
    valid: std.atomic.Value(bool) = .init(true),
};

var active_reentrant_script_hook: ?*ReentrantScriptHook = null;

fn reentrantScriptHook(instance_id: i32, info: debugger_mod.ScriptInfo) void {
    const state = active_reentrant_script_hook orelse return;
    if (instance_id != state.id) return;
    const call = state.calls.fetchAdd(1, .seq_cst);
    if (call == 0) debugger_mod.noteScript(instance_id, "hook-reentrant-nested.js", "nested");
    // info is an owned publication copy and remains readable across the nested journal update above.
    if (info.url.len == 0 or info.source.len == 0) state.valid.store(false, .seq_cst);
    if (debugger_mod.scriptById(instance_id, info.id)) |copy| {
        defer debugger_mod.freeScriptInfo(copy);
        if (!std.mem.eql(u8, copy.source, info.source)) state.valid.store(false, .seq_cst);
    } else state.valid.store(false, .seq_cst);
}

const ScriptJournalRace = struct {
    id: i32,
    writer_done: std.atomic.Value(bool) = .init(false),
    reader_failed: std.atomic.Value(bool) = .init(false),

    fn writer(self: *ScriptJournalRace) void {
        for (0..1024) |index| {
            var url: [48]u8 = undefined;
            var source: [48]u8 = undefined;
            const url_text = std.fmt.bufPrint(&url, "race-{d}.js", .{index}) catch continue;
            const source_text = std.fmt.bufPrint(&source, "{d}", .{index}) catch continue;
            debugger_mod.noteScript(self.id, url_text, source_text);
        }
        self.writer_done.store(true, .seq_cst);
    }

    fn reader(self: *ScriptJournalRace) void {
        while (!self.writer_done.load(.seq_cst)) {
            const scripts = debugger_mod.snapshotScripts(self.id);
            for (scripts) |script| {
                if (script.id == 0 or script.url.len == 0) self.reader_failed.store(true, .seq_cst);
            }
            debugger_mod.freeScriptSnapshot(scripts);
        }
    }
};

const SameLinePauseProbe = struct {
    id: i32,
    barrier_calls: std.atomic.Value(usize) = .init(0),
    barrier_entered: std.atomic.Value(bool) = .init(false),
    release_barrier: std.atomic.Value(bool) = .init(false),
    pause_calls: std.atomic.Value(usize) = .init(0),
    first_pause_entered: std.atomic.Value(bool) = .init(false),
    release_first_pause: std.atomic.Value(bool) = .init(false),

    fn barrier(instance_id: i32, _: value.NativeArgs) value.NativeResult {
        const self = active_same_line_pause_probe orelse return .undefined_val;
        if (self.id == instance_id and self.barrier_calls.fetchAdd(1, .seq_cst) == 0) {
            self.barrier_entered.store(true, .seq_cst);
            while (!self.release_barrier.load(.seq_cst)) std.Thread.yield() catch {};
        }
        return .undefined_val;
    }

    fn onPause(instance_id: i32, _: debugger_mod.PauseInfo) void {
        const self = active_same_line_pause_probe orelse return;
        if (self.id != instance_id) return;
        if (self.pause_calls.fetchAdd(1, .seq_cst) == 0) {
            self.first_pause_entered.store(true, .seq_cst);
            while (!self.release_first_pause.load(.seq_cst)) std.Thread.yield() catch {};
        }
    }
};

var active_same_line_pause_probe: ?*SameLinePauseProbe = null;

fn updateHooksWhileRunning(state: *HookRaceState) void {
    while (!state.stop.load(.seq_cst)) {
        debugger_mod.setHooks(countPauseA, countScriptA);
        debugger_mod.setHooks(countPauseB, countScriptB);
        _ = state.updates.fetchAdd(1, .seq_cst);
    }
}

const EvalBox = struct {
    id: i32,
    script: []const u8,
    filename: []const u8,
    status_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: []const u8 = "",
};

fn evalOnThread(box: *EvalBox) void {
    const res = engine.evalScript(box.id, box.script, box.filename);
    box.status_ok.store(res.err == null, .seq_cst);
    if (res.result) |text| {
        box.result = std.heap.c_allocator.dupe(u8, text) catch "";
    }
    if (res.err) |text| {
        if (res.err_is_heap) std.heap.c_allocator.free(text);
    }
    if (res.result) |text| std.heap.c_allocator.free(text);
}

fn waitPaused(id: i32) bool {
    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        if (debugger_mod.isPaused(id)) return true;
        io.sleepMs(1);
    }
    return false;
}

/// Direct debugger API tests deliberately opt into the otherwise cold debugger binding. Production instances are armed by `Debugger.enable`.
fn attachDebuggerForTest(id: i32) !void {
    const instance = instance_map.getInstance(id) orelse return error.MissingEngine;
    _ = debugger_mod.attach(id, @ptrCast(@constCast(instance.runtime)));
}

const NativeFrameDebuggerToggle = struct {
    id: i32,
    attach_ok: std.atomic.Value(bool) = .init(false),
    breakpoint_id: std.atomic.Value(u32) = .init(0),

    fn attach(instance_id: i32, _: value.NativeArgs) value.NativeResult {
        const self = active_native_frame_debugger_toggle orelse return .undefined_val;
        if (instance_id != self.id) return .undefined_val;
        const instance = instance_map.getInstance(instance_id) orelse return .undefined_val;
        self.attach_ok.store(debugger_mod.attach(instance_id, @ptrCast(@constCast(instance.runtime))), .seq_cst);
        self.breakpoint_id.store(debugger_mod.setBreakpoint(instance_id, "native-frame-attach.js", 3), .seq_cst);
        return .undefined_val;
    }

    fn detach(instance_id: i32, _: value.NativeArgs) value.NativeResult {
        const self = active_native_frame_debugger_toggle orelse return .undefined_val;
        if (instance_id == self.id) debugger_mod.detach(instance_id);
        return .undefined_val;
    }
};

var active_native_frame_debugger_toggle: ?*NativeFrameDebuggerToggle = null;

const DuplicateCreateRace = struct {
    id: i32,
    hook_calls: std.atomic.Value(usize) = .init(0),
    first_release: std.atomic.Value(bool) = .init(false),
    second_done: std.atomic.Value(bool) = .init(false),
    first_result: bool = false,
    second_result: bool = false,

    fn beforeAttach(_: i32, ctx: ?*anyopaque) void {
        const self: *DuplicateCreateRace = @ptrCast(@alignCast(ctx.?));
        const call = self.hook_calls.fetchAdd(1, .seq_cst);
        if (call == 0) {
            while (!self.first_release.load(.seq_cst)) std.Thread.yield() catch {};
        }
    }

    fn firstCreate(self: *DuplicateCreateRace) void {
        self.first_result = engine.create(self.id, .{});
    }

    fn secondCreate(self: *DuplicateCreateRace) void {
        self.second_result = engine.create(self.id, .{});
        self.second_done.store(true, .seq_cst);
    }
};

const InspectorEnabledTests = if (@import("build_options").inspector) struct {
    test "duplicate concurrent create preserves the winning debugger binding" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        var race = DuplicateCreateRace{ .id = id };
        engine.setCreateBeforeDebuggerAttachHookForTesting(DuplicateCreateRace.beforeAttach, &race);
        defer engine.setCreateBeforeDebuggerAttachHookForTesting(null, null);

        const first = try std.Thread.spawn(.{}, DuplicateCreateRace.firstCreate, .{&race});
        var first_joined = false;
        defer {
            race.first_release.store(true, .seq_cst);
            if (!first_joined) first.join();
        }
        var spins: usize = 0;
        while (spins < 2000 and race.hook_calls.load(.seq_cst) == 0) : (spins += 1) io.sleepMs(1);
        try testing.expectEqual(@as(usize, 1), race.hook_calls.load(.seq_cst));

        const second = try std.Thread.spawn(.{}, DuplicateCreateRace.secondCreate, .{&race});
        var second_joined = false;
        defer if (!second_joined) second.join();
        spins = 0;
        while (spins < 2000 and !race.second_done.load(.seq_cst)) : (spins += 1) io.sleepMs(1);
        try testing.expect(race.second_done.load(.seq_cst));
        race.first_release.store(true, .seq_cst);
        first.join();
        first_joined = true;
        second.join();
        second_joined = true;
        try testing.expect(race.second_result);
        try testing.expect(!race.first_result);
        defer engine.destroy(id);

        try attachDebuggerForTest(id);
        try testing.expect(debugger_mod.setBreakpoint(id, "duplicate-create.js", 1) != 0);
        var box = EvalBox{
            .id = id,
            .script = "1;\n2;\n",
            .filename = "duplicate-create.js",
        };
        const eval_thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
        var joined = false;
        defer if (!joined) {
            debugger_mod.resumeExecution(id);
            eval_thread.join();
        };
        try testing.expect(waitPaused(id));
        debugger_mod.resumeExecution(id);
        eval_thread.join();
        joined = true;
        try testing.expect(box.status_ok.load(.seq_cst));
        std.heap.c_allocator.free(box.result);
    }
};

comptime {
    _ = InspectorEnabledTests;
}

const CreatePublicationRace = struct {
    id: i32,
    initialization_entered: std.atomic.Value(bool) = .init(false),
    release_initialization: std.atomic.Value(bool) = .init(false),
    reader_started: std.atomic.Value(bool) = .init(false),
    reader_returned: std.atomic.Value(bool) = .init(false),
    reader_saw_instance: bool = false,
    create_result: bool = false,

    fn pauseInitialization(_: i32, ctx: ?*anyopaque) void {
        const self: *CreatePublicationRace = @ptrCast(@alignCast(ctx.?));
        self.initialization_entered.store(true, .seq_cst);
        while (!self.release_initialization.load(.seq_cst)) std.Thread.yield() catch {};
    }

    fn create(self: *CreatePublicationRace) void {
        self.create_result = engine.create(self.id, .{});
    }

    fn readInstance(self: *CreatePublicationRace) void {
        self.reader_started.store(true, .seq_cst);
        self.reader_saw_instance = instance_map.getPtrs(self.id) != null;
        self.reader_returned.store(true, .seq_cst);
    }
};

test "instance readers wait until debugger initialization finishes" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const id = helpers.nextInstanceId();
    var race = CreatePublicationRace{ .id = id };
    engine.setCreateAfterInsertHookForTesting(CreatePublicationRace.pauseInitialization, &race);
    defer engine.setCreateAfterInsertHookForTesting(null, null);

    const creator = try std.Thread.spawn(.{}, CreatePublicationRace.create, .{&race});
    var creator_joined = false;
    defer {
        race.release_initialization.store(true, .seq_cst);
        if (!creator_joined) creator.join();
        if (race.create_result) engine.destroy(id);
    }

    var spins: usize = 0;
    while (spins < 2000 and !race.initialization_entered.load(.seq_cst)) : (spins += 1) io.sleepMs(1);
    try testing.expect(race.initialization_entered.load(.seq_cst));

    const reader = try std.Thread.spawn(.{}, CreatePublicationRace.readInstance, .{&race});
    var reader_joined = false;
    defer if (!reader_joined) {
        race.release_initialization.store(true, .seq_cst);
        reader.join();
    };
    spins = 0;
    while (spins < 2000 and !race.reader_started.load(.seq_cst)) : (spins += 1) io.sleepMs(1);
    try testing.expect(race.reader_started.load(.seq_cst));

    spins = 0;
    while (spins < 100 and !race.reader_returned.load(.seq_cst)) : (spins += 1) io.sleepMs(1);
    const reader_observed_partial_instance = race.reader_returned.load(.seq_cst);
    race.release_initialization.store(true, .seq_cst);
    creator.join();
    creator_joined = true;
    reader.join();
    reader_joined = true;

    try testing.expect(race.create_result);
    try testing.expect(!reader_observed_partial_instance);
    try testing.expect(race.reader_saw_instance);
}

const InspectorEnabledTests2 = if (@import("build_options").inspector) struct {
    test "debugger: a breakpoint pauses on that line and resume finishes the script" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                const line = debugger_mod.setBreakpoint(instance_id, "pause.js", 2);
                try testing.expect(line != 0);

                var box = EvalBox{
                    .id = instance_id,
                    .script = "var n = 1;\nn = 2;\nn\n",
                    .filename = "pause.js",
                };
                const thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
                var joined = false;
                defer if (!joined) {
                    debugger_mod.resumeExecution(instance_id);
                    thread.join();
                };

                try testing.expect(waitPaused(instance_id));
                try testing.expectEqual(@as(i32, 2), debugger_mod.pausedLine(instance_id));
                debugger_mod.resumeExecution(instance_id);
                thread.join();
                joined = true;
                try testing.expect(box.status_ok.load(.seq_cst));
                try testing.expectEqualStrings("2", box.result);
            }
        }.run);
    }

    test "debugger: native callback attaches cold runtime before the next outer-frame location" {
        if (comptime backend.active_backend != .quickjs_ng) return;
        const id = helpers.nextInstanceId();
        var toggle = NativeFrameDebuggerToggle{ .id = id };
        active_native_frame_debugger_toggle = &toggle;
        defer active_native_frame_debugger_toggle = null;
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                const state = active_native_frame_debugger_toggle orelse return error.MissingNativeFrameToggle;
                try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(instance_id));
                value.registerFunction(instance_id, null, "__attach_debugger_during_frame__", &NativeFrameDebuggerToggle.attach);
                var box = EvalBox{
                    .id = instance_id,
                    .script = "globalThis.beforeNativeAttach = 1;\n__attach_debugger_during_frame__();\nglobalThis.afterNativeAttach = 2;\nglobalThis.afterNativeAttach;\n",
                    .filename = "native-frame-attach.js",
                };
                const thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
                var joined = false;
                defer if (!joined) {
                    debugger_mod.resumeExecution(instance_id);
                    thread.join();
                };

                try testing.expect(waitPaused(instance_id));
                try testing.expect(state.attach_ok.load(.seq_cst));
                try testing.expect(state.breakpoint_id.load(.seq_cst) != 0);
                try testing.expectEqual(@as(i32, 3), debugger_mod.pausedLine(instance_id));
                debugger_mod.resumeExecution(instance_id);
                thread.join();
                joined = true;
                try testing.expect(box.status_ok.load(.seq_cst));
                try testing.expectEqualStrings("2", box.result);
            }
        }.run);
    }

    test "debugger: native callback detaches before the next outer-frame location" {
        if (comptime backend.active_backend != .quickjs_ng) return;
        const id = helpers.nextInstanceId();
        var toggle = NativeFrameDebuggerToggle{ .id = id };
        active_native_frame_debugger_toggle = &toggle;
        defer active_native_frame_debugger_toggle = null;
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                try testing.expect(debugger_mod.setBreakpoint(instance_id, "native-frame-detach.js", 3) != 0);
                value.registerFunction(instance_id, null, "__detach_debugger_during_frame__", &NativeFrameDebuggerToggle.detach);
                const evaluated = engine.evalScript(
                    instance_id,
                    "globalThis.beforeNativeDetach = 1;\n__detach_debugger_during_frame__();\nglobalThis.afterNativeDetach = 2;\nglobalThis.afterNativeDetach;\n",
                    "native-frame-detach.js",
                );
                defer helpers.freeEvalResult(evaluated);
                try testing.expect(evaluated.err == null);
                try testing.expectEqualStrings("2", evaluated.result orelse return error.MissingResult);
                try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(instance_id));
            }
        }.run);
    }

    test "debugger: hooks can be updated while the script thread invokes them" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                var state = HookRaceState{};
                active_hook_test = &state;
                defer {
                    state.stop.store(true, .seq_cst);
                    debugger_mod.setHooks(null, null);
                    active_hook_test = null;
                }

                try testing.expect(debugger_mod.setBreakpoint(instance_id, "hook-race.js", 1) != 0);
                debugger_mod.setHooks(countPauseA, countScriptA);
                const updater = try std.Thread.spawn(.{}, updateHooksWhileRunning, .{&state});
                var updater_joined = false;
                defer if (!updater_joined) {
                    state.stop.store(true, .seq_cst);
                    updater.join();
                };

                var box = EvalBox{
                    .id = instance_id,
                    .script = "1;\n2;\n",
                    .filename = "hook-race.js",
                };
                const thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
                var joined = false;
                defer if (!joined) {
                    debugger_mod.resumeExecution(instance_id);
                    thread.join();
                };

                try testing.expect(waitPaused(instance_id));
                debugger_mod.resumeExecution(instance_id);
                thread.join();
                joined = true;
                state.stop.store(true, .seq_cst);
                updater.join();
                updater_joined = true;

                try testing.expect(box.status_ok.load(.seq_cst));
                try testing.expect(state.updates.load(.seq_cst) > 0);
                try testing.expect(state.pause_calls.load(.seq_cst) > 0);
                try testing.expect(state.script_calls.load(.seq_cst) > 0);
            }
        }.run);
    }

    test "debugger: step over stops on the next line" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                try testing.expect(debugger_mod.setBreakpoint(instance_id, "step.js", 1) != 0);
                var box = EvalBox{
                    .id = instance_id,
                    .script = "var n = 1;\nn = n + 1;\nn\n",
                    .filename = "step.js",
                };
                const thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
                var joined = false;
                defer if (!joined) {
                    debugger_mod.resumeExecution(instance_id);
                    thread.join();
                };
                try testing.expect(waitPaused(instance_id));
                try testing.expectEqual(@as(i32, 1), debugger_mod.pausedLine(instance_id));
                debugger_mod.stepOver(instance_id);
                var i: u32 = 0;
                while (i < 2000) : (i += 1) {
                    if (debugger_mod.isPaused(instance_id) and debugger_mod.pausedLine(instance_id) == 2) break;
                    io.sleepMs(1);
                }
                try testing.expectEqual(@as(i32, 2), debugger_mod.pausedLine(instance_id));
                debugger_mod.resumeExecution(instance_id);
                thread.join();
                joined = true;
                try testing.expectEqualStrings("2", box.result);
            }
        }.run);
    }

    test "debugger: script journal deduplicates exact sources and bounds dynamic sources" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                var i: u32 = 0;
                while (i < 1000) : (i += 1) {
                    const res = engine.evalScript(instance_id, "1", "same.js");
                    if (res.result) |text| std.heap.c_allocator.free(text);
                    if (res.err) |text| if (res.err_is_heap) std.heap.c_allocator.free(text);
                    try testing.expect(res.err == null);
                }
                const same = debugger_mod.snapshotScripts(instance_id);
                defer debugger_mod.freeScriptSnapshot(same);
                try testing.expectEqual(@as(usize, 1), same.len);
                const first_dynamic_id = same[0].id;
                const held = debugger_mod.scriptById(instance_id, first_dynamic_id) orelse return error.MissingHeldScript;
                defer debugger_mod.freeScriptInfo(held);
                i = 0;
                while (i < debugger_mod.max_retained_scripts + 32) : (i += 1) {
                    const name = try std.fmt.allocPrint(std.heap.c_allocator, "s{d}.js", .{i});
                    defer std.heap.c_allocator.free(name);
                    const source = try std.fmt.allocPrint(std.heap.c_allocator, "{d}", .{i});
                    defer std.heap.c_allocator.free(source);
                    const res = engine.evalScript(instance_id, source, name);
                    if (res.result) |text| std.heap.c_allocator.free(text);
                    if (res.err) |text| {
                        if (res.err_is_heap) std.heap.c_allocator.free(text);
                    }
                    try testing.expect(res.err == null);
                }
                const scripts = debugger_mod.snapshotScripts(instance_id);
                defer debugger_mod.freeScriptSnapshot(scripts);
                try testing.expect(scripts.len <= debugger_mod.max_retained_scripts);
                try testing.expect(debugger_mod.scriptById(instance_id, first_dynamic_id) == null);
                // Both copies predate eviction and must remain independently valid.
                try testing.expectEqualStrings("1", same[0].source);
                try testing.expectEqualStrings("1", held.source);
                const newest = scripts[scripts.len - 1];
                try testing.expectEqualStrings("287", newest.source);
                const owned = debugger_mod.scriptById(instance_id, newest.id) orelse return error.MissingNewestScript;
                defer debugger_mod.freeScriptInfo(owned);
                try testing.expectEqualStrings(newest.source, owned.source);
            }
        }.run);
    }

    test "debugger: oversized newest script remains complete and old ids are evicted" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                debugger_mod.noteScript(instance_id, "old-source.js", "old");
                const old_id = debugger_mod.scriptIdForUrl(instance_id, "old-source.js");
                const oversized = try std.heap.c_allocator.alloc(u8, debugger_mod.max_retained_source_bytes + 1);
                defer std.heap.c_allocator.free(oversized);
                @memset(oversized, 'x');
                debugger_mod.noteScript(instance_id, "oversized-source.js", oversized);
                const scripts = debugger_mod.snapshotScripts(instance_id);
                defer debugger_mod.freeScriptSnapshot(scripts);
                try testing.expectEqual(@as(usize, 1), scripts.len);
                try testing.expectEqualStrings("oversized-source.js", scripts[0].url);
                try testing.expectEqual(oversized.len, scripts[0].source.len);
                try testing.expect(debugger_mod.scriptById(instance_id, old_id) == null);
            }
        }.run);
    }

    test "debugger: owned script snapshots survive eviction and concurrent readers" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                var race = ScriptJournalRace{ .id = instance_id };
                const reader = try std.Thread.spawn(.{}, ScriptJournalRace.reader, .{&race});
                const writer = try std.Thread.spawn(.{}, ScriptJournalRace.writer, .{&race});
                writer.join();
                reader.join();
                try testing.expect(!race.reader_failed.load(.seq_cst));
            }
        }.run);
    }

    test "debugger: script hook can reenter after publication" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        var state = ReentrantScriptHook{ .id = id };
        active_reentrant_script_hook = &state;
        debugger_mod.setHooks(null, reentrantScriptHook);
        defer {
            debugger_mod.setHooks(null, null);
            active_reentrant_script_hook = null;
        }
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                debugger_mod.noteScript(instance_id, "hook-reentrant.js", "outer");
            }
        }.run);
        try testing.expectEqual(@as(usize, 2), state.calls.load(.seq_cst));
        try testing.expect(state.valid.load(.seq_cst));
    }

    test "debugger: pause on all exceptions, not on caught exceptions" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                debugger_mod.setExceptionPause(instance_id, .all);
                var box = EvalBox{
                    .id = instance_id,
                    .script = "throw new Error('boom');",
                    .filename = "throw.js",
                };
                const thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
                var joined = false;
                defer if (!joined) {
                    debugger_mod.resumeExecution(instance_id);
                    thread.join();
                };
                try testing.expect(waitPaused(instance_id));
                try testing.expectEqual(debugger_mod.PauseReason.exception, debugger_mod.pausedReason(instance_id));
                debugger_mod.resumeExecution(instance_id);
                thread.join();
                joined = true;
                try testing.expect(!box.status_ok.load(.seq_cst));

                debugger_mod.setExceptionPause(instance_id, .uncaught);
                var caught_box = EvalBox{
                    .id = instance_id,
                    .script = "try { throw 1 } catch (e) { e }",
                    .filename = "catch.js",
                };
                const caught_thread = try std.Thread.spawn(.{}, evalOnThread, .{&caught_box});
                var caught_joined = false;
                defer if (!caught_joined) {
                    debugger_mod.resumeExecution(instance_id);
                    caught_thread.join();
                };
                var wait: u32 = 0;
                while (wait < 500) : (wait += 1) {
                    if (!debugger_mod.isPaused(instance_id)) {
                        // The script either finished or has not started. Join only after a short quiet period so a late pause is visible.
                    }
                    io.sleepMs(1);
                }
                try testing.expect(!debugger_mod.isPaused(instance_id));
                caught_thread.join();
                caught_joined = true;
                try testing.expect(caught_box.status_ok.load(.seq_cst));
            }
        }.run);
    }

    test "debugger: requestPause stops a running script" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                debugger_mod.requestPause(instance_id);
                var box = EvalBox{
                    .id = instance_id,
                    .script = "var n = 0;\nfunction tick() { n = n + 1; }\nfor (var i = 0; i < 1000; i++) tick();\nn\n",
                    .filename = "loop.js",
                };
                const thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
                var joined = false;
                defer if (!joined) {
                    debugger_mod.resumeExecution(instance_id);
                    thread.join();
                };
                try testing.expect(waitPaused(instance_id));
                try testing.expectEqual(debugger_mod.PauseReason.other, debugger_mod.pausedReason(instance_id));
                debugger_mod.resumeExecution(instance_id);
                thread.join();
                joined = true;
                try testing.expect(box.status_ok.load(.seq_cst));
            }
        }.run);
    }

    test "debugger: requestPause stops a same-line loop" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const id = helpers.nextInstanceId();
        try helpers.withEngine(id, .{}, struct {
            fn run(instance_id: i32) !void {
                try attachDebuggerForTest(instance_id);
                try testing.expect(runtime_control.init(instance_id));
                defer _ = runtime_control.deinit(instance_id);

                var probe = SameLinePauseProbe{ .id = instance_id };
                active_same_line_pause_probe = &probe;
                value.registerFunction(instance_id, null, "__pause_barrier__", &SameLinePauseProbe.barrier);
                debugger_mod.setHooks(SameLinePauseProbe.onPause, null);
                defer {
                    probe.release_barrier.store(true, .seq_cst);
                    probe.release_first_pause.store(true, .seq_cst);
                    debugger_mod.setHooks(null, null);
                    active_same_line_pause_probe = null;
                }

                var box = EvalBox{
                    .id = instance_id,
                    .script = "var n = 0;\nwhile (n < 100000) { __pause_barrier__(); n++; }\nn\n",
                    .filename = "tight.js",
                };
                const thread = try std.Thread.spawn(.{}, evalOnThread, .{&box});
                var joined = false;
                defer if (!joined) {
                    debugger_mod.abandon(instance_id);
                    probe.release_barrier.store(true, .seq_cst);
                    probe.release_first_pause.store(true, .seq_cst);
                    _ = runtime_control.requestInterrupt(instance_id);
                    thread.join();
                    if (box.result.len > 0) std.heap.c_allocator.free(box.result);
                };

                var barrier_attempts: u32 = 0;
                while (barrier_attempts < 2000 and !probe.barrier_entered.load(.seq_cst)) : (barrier_attempts += 1) io.sleepMs(1);
                try testing.expect(probe.barrier_entered.load(.seq_cst));
                debugger_mod.requestPause(instance_id);
                probe.release_barrier.store(true, .seq_cst);

                var attempts: u32 = 0;
                while (attempts < 2000 and !probe.first_pause_entered.load(.seq_cst)) : (attempts += 1) io.sleepMs(1);
                try testing.expect(probe.first_pause_entered.load(.seq_cst));
                try testing.expectEqual(@as(i32, 2), debugger_mod.pausedLine(instance_id));
                debugger_mod.resumeExecution(instance_id);
                debugger_mod.requestPause(instance_id);
                probe.release_first_pause.store(true, .seq_cst);

                var second_pause_attempts: u32 = 0;
                while (second_pause_attempts < 2000 and
                    !(debugger_mod.isPaused(instance_id) and probe.pause_calls.load(.seq_cst) >= 2)) : (second_pause_attempts += 1)
                {
                    io.sleepMs(1);
                }
                try testing.expect(debugger_mod.isPaused(instance_id));
                try testing.expectEqual(@as(usize, 2), probe.pause_calls.load(.seq_cst));
                try testing.expectEqual(debugger_mod.PauseReason.other, debugger_mod.pausedReason(instance_id));
                try testing.expectEqual(@as(i32, 2), debugger_mod.pausedLine(instance_id));

                debugger_mod.resumeExecution(instance_id);
                thread.join();
                joined = true;
                try testing.expect(box.status_ok.load(.seq_cst));
                try testing.expectEqualStrings("100000", box.result);
                if (box.result.len > 0) std.heap.c_allocator.free(box.result);
            }
        }.run);
    }
};

comptime {
    _ = InspectorEnabledTests2;
}
