//! Line breakpoints for the QuickJS backend.
//!
//! QuickJS reports each source line through `JS_SetLocationHandler` and each thrown exception through `JS_SetExceptionHandler`. This file decides whether to pause, then blocks the engine thread until `resumeExecution` or a step clears the pause. While paused it drains host tasks so a debugger command posted from another thread can run against the live stack. JavaScriptCore has no equivalent hook; attach is a no-op there.

const std = @import("std");
const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const io = @import("../platform/io.zig");
const sync = @import("zev");

pub const PauseReason = enum { breakpoint, step, exception, other };

pub const PauseInfo = struct {
    reason: PauseReason,
    line: i32,
    column: i32,
    url: []const u8,
};

pub const ScriptInfo = struct {
    id: u32,
    url: []const u8,
    source: []const u8,
    end_line: i32,
    end_column: i32,
    hash: []const u8,
    source_map_url: []const u8,
};

/// The debugger journal is a bounded diagnostic cache, not a source archive. The newest source is retained whole even when it alone exceeds the byte budget, so Debugger.getScriptSource never receives a fabricated truncation.
pub const max_retained_scripts: usize = 256;
pub const max_retained_source_bytes: usize = 8 * 1024 * 1024;

pub const PauseHook = *const fn (instance_id: i32, info: PauseInfo) void;
pub const ScriptHook = *const fn (instance_id: i32, info: ScriptInfo) void;

pub const ExceptionPause = enum(u8) { none, uncaught, all };

const StepMode = enum { run, step_in, step_over, step_out };

const Breakpoint = struct {
    id: u32,
    url: []u8,
    line: i32,
    /// 0-based column. The stop moves to the first non-whitespace column at or after this one.
    column: i32 = 0,
    url_is_regex: bool = false,
    condition: []u8 = &.{},
};

const Script = struct {
    id: u32,
    url: []u8,
    source: []u8,
    end_line: i32,
    end_column: i32,
    hash: [16]u8,
    source_map_url: []u8,
    // Journal storage is FIFO, but a source can be evaluated again after a newer revision with the same URL has been recorded.
    last_note_generation: u64 = 0,
    // Exact bytecode locations collected by the QuickJS-NG evaluator before the temporary top-level bytecode is released. These are deliberately separate from the source journal: scanning source text would claim comments and whitespace are executable locations.
    break_locations: std.ArrayList(SourceLocation) = .empty,
    break_locations_collected: bool = false,
    break_locations_truncated: bool = false,
};

const SourceLocation = struct {
    line: i32,
    column: i32,
};

const Binding = struct {
    instance_id: i32,
    runtime: ?*anyopaque,
    armed: std.atomic.Value(bool) = .init(false),
    // Set during engine teardown. A binding can retain reader-thread configuration, but it must never be attached to a destroyed engine.
    abandoned: bool = false,
    handler_install_thread_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    alive: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
    pause: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    suppress: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    skip_all_pauses: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    breakpoints_active: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
    break_requested: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    exception_mode: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    // One exception pause per throw. Follow-up JS_Throw calls from the same exception are ignored until the next source line.
    exception_hold: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    // debugger; pauses only after Debugger.enable.
    break_on_debugger: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    paused_line: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    paused_column: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    paused_depth: i32 = 0,
    paused_reason: PauseReason = .breakpoint,
    mode: StepMode = .run,
    next_breakpoint_id: u32 = 1,
    next_script_id: u32 = 1,
    next_note_generation: u64 = 1,
    mutex: sync.Mutex = .{},
    breakpoints: std.ArrayList(Breakpoint) = .empty,
    scripts: std.ArrayList(Script) = .empty,
    script_bytes: usize = 0,
    // `noteScript` runs immediately before each host evaluation. This retains the exact journal entry even when a URL has several source revisions.
    active_script_id: u32 = 0,
    // The native collector ends with a filename-less completion callback. Remember the entry chosen by its location callbacks until that marker.
    collecting_script_id: u32 = 0,
    paused_script_tag: u64 = 0,
    paused_url: [512]u8 = undefined,
    paused_url_len: usize = 0,
    // After resume, ignore this exact frame line once. Nested eval resets QuickJS's last-line cache, so the same breakpoint would hit again. A callee's lines must not cancel that skip, or step-over stops on the call a second time when the callee returns.
    skip_line: i32 = -1,
    skip_depth: i32 = 0,
    skip_url: [512]u8 = undefined,
    skip_url_len: usize = 0,
    skip_script_tag: u64 = 0,
    skip_seen_same: bool = false,
    skip_saw_deeper: bool = false,
    blackbox: std.ArrayList([]u8) = .empty,
};

pub const DebugFrame = struct {
    name: []u8,
    url: []u8,
    line: i32,
    column: i32,
    /// Zero is an explicitly unknown native compilation unit.
    script_tag: u64 = 0,
};

pub const BreakLocation = struct {
    breakpoint_id: u32,
    script_id: u32,
    line: i32,
    column: i32,
};

pub const PossibleBreakpointsError = error{
    ScriptUnknown,
    LocationsUnavailable,
    LocationsTruncated,
};

var table_mutex: sync.Mutex = .{};
var table: ?std.AutoHashMap(i32, *Binding) = null;
var pause_hook: std.atomic.Value(?PauseHook) = .init(null);
var script_hook: std.atomic.Value(?ScriptHook) = .init(null);

test "debugger hook storage uses atomic publication slots" {
    try std.testing.expect(@TypeOf(pause_hook) == std.atomic.Value(?PauseHook));
    try std.testing.expect(@TypeOf(script_hook) == std.atomic.Value(?ScriptHook));
}

fn bindings() *std.AutoHashMap(i32, *Binding) {
    if (table == null) {
        table = std.AutoHashMap(i32, *Binding).init(std.heap.c_allocator);
    }
    return &table.?;
}

pub fn setHooks(on_pause: ?PauseHook, on_script: ?ScriptHook) void {
    pause_hook.store(on_pause, .seq_cst);
    script_hook.store(on_script, .seq_cst);
}

pub fn attach(instance_id: i32, runtime: *anyopaque) bool {
    if (comptime !@import("build_options").inspector) return false;
    if (comptime !backend.supportsDebugger(backend.active_backend)) return false;
    table_mutex.lock();
    defer table_mutex.unlock();
    const map = bindings();
    if (map.get(instance_id)) |existing| {
        // A binding may have been prepared by the transport while the first Debugger.enable waits for an owner turn. Only this owner-side path gives it a runtime and installs native callbacks.
        existing.mutex.lock();
        defer existing.mutex.unlock();
        if (existing.abandoned) return false;
        existing.runtime = runtime;
        // Only a cold-to-live admission discards stale pause state. A second DevTools session must not erase a pause requested by an already live session while it waits for the owner to run.
        if (existing.alive.load(.seq_cst) == 0) {
            existing.break_requested.store(0, .seq_cst);
        }
        existing.alive.store(1, .seq_cst);
        arm(existing);
        return true;
    }
    const binding = std.heap.c_allocator.create(Binding) catch return false;
    binding.* = .{
        .instance_id = instance_id,
        .runtime = runtime,
    };
    map.put(instance_id, binding) catch {
        destroyBinding(binding);
        return false;
    };
    binding.mutex.lock();
    arm(binding);
    binding.mutex.unlock();
    return true;
}

/// Retain reader-thread Debugger configuration while the first enable is queued. A prepared binding intentionally has no runtime and is never armed; `attach` is the sole owner-thread transition that installs native callbacks.
pub fn prepare(instance_id: i32) bool {
    if (comptime !@import("build_options").inspector) return false;
    if (comptime !backend.supportsDebugger(backend.active_backend)) return false;
    table_mutex.lock();
    defer table_mutex.unlock();
    const map = bindings();
    if (map.get(instance_id)) |existing| {
        existing.mutex.lock();
        defer existing.mutex.unlock();
        return !existing.abandoned;
    }
    const binding = std.heap.c_allocator.create(Binding) catch return false;
    binding.* = .{
        .instance_id = instance_id,
        .runtime = null,
        .alive = std.atomic.Value(u8).init(0),
    };
    map.put(instance_id, binding) catch {
        destroyBinding(binding);
        return false;
    };
    return true;
}

pub fn abandon(instance_id: i32) void {
    table_mutex.lock();
    defer table_mutex.unlock();
    const map = table orelse return;
    const binding = map.get(instance_id) orelse return;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    binding.abandoned = true;
    binding.alive.store(0, .seq_cst);
    binding.pause.store(0, .seq_cst);
    binding.break_requested.store(0, .seq_cst);
}

pub fn detach(instance_id: i32) void {
    table_mutex.lock();
    const removed = if (table) |*map| map.fetchRemove(instance_id) else null;
    table_mutex.unlock();
    const binding = removed orelse return;
    binding.value.mutex.lock();
    binding.value.alive.store(0, .seq_cst);
    binding.value.pause.store(0, .seq_cst);
    binding.value.break_requested.store(0, .seq_cst);
    disarm(binding.value);
    binding.value.mutex.unlock();
    destroyBinding(binding.value);
}

/// Stop native collection while retaining the binding's monotonically growing identity counters. Old bytecode tags must never resolve to a newly reused script id when a later DevTools session starts.
pub fn coolDown(instance_id: i32) void {
    const binding = lockBinding(instance_id) orelse return;
    defer binding.mutex.unlock();
    binding.alive.store(0, .seq_cst);
    binding.pause.store(0, .seq_cst);
    binding.break_requested.store(0, .seq_cst);
    disarm(binding);
    for (binding.scripts.items) |script| freeScript(script);
    binding.scripts.clearRetainingCapacity();
    binding.script_bytes = 0;
    binding.active_script_id = 0;
    binding.collecting_script_id = 0;
    binding.paused_script_tag = 0;
}

pub fn setBreakpointsActive(instance_id: i32, active: bool) void {
    const binding = lookup(instance_id) orelse return;
    binding.breakpoints_active.store(if (active) 1 else 0, .seq_cst);
}

pub fn setSkipAllPauses(instance_id: i32, skip: bool) void {
    const binding = lookup(instance_id) orelse return;
    binding.skip_all_pauses.store(if (skip) 1 else 0, .seq_cst);
}

pub fn setExceptionPause(instance_id: i32, mode: ExceptionPause) void {
    const binding = lookup(instance_id) orelse return;
    binding.exception_mode.store(@backingInt(mode), .seq_cst);
}

/// A pause on an exception suppresses the next throw until execution reaches another line. A later eval is a new script, so it must honor the mode.
pub fn clearExceptionHold(instance_id: i32) void {
    const binding = lookup(instance_id) orelse return;
    binding.exception_hold.store(0, .seq_cst);
}

/// `debugger;` pauses only while this is set. Debugger.enable turns it on.
pub fn setDebuggerStatements(instance_id: i32, enabled: bool) void {
    const binding = lookup(instance_id) orelse return;
    binding.break_on_debugger.store(if (enabled) 1 else 0, .seq_cst);
}

pub fn debuggerStatementsEnabled(instance_id: i32) bool {
    const binding = lookup(instance_id) orelse return false;
    return binding.break_on_debugger.load(.seq_cst) != 0;
}

pub fn handlerInstallThreadId(instance_id: i32) u64 {
    const binding = lookup(instance_id) orelse return 0;
    return binding.handler_install_thread_id.load(.seq_cst);
}

pub fn requestPause(instance_id: i32) void {
    const binding = lockBinding(instance_id) orelse return;
    // A Debugger.pause received after the final session closes must not leak into a later session, nor may it touch the runtime from the reader.
    if (binding.alive.load(.seq_cst) == 0 or binding.abandoned) {
        binding.break_requested.store(0, .seq_cst);
        binding.mutex.unlock();
        return;
    }
    binding.break_requested.store(1, .seq_cst);
    if (comptime @import("build_options").inspector and backend.isQuickJsApiBackend(backend.active_backend)) {
        const qjs = @import("../backend.zig").ActiveEngineModule.c_api.qjs;
        if (binding.runtime) |rt| qjs.JS_RequestLocationCallback(@ptrCast(rt));
    }
    binding.mutex.unlock();
}

pub fn setBreakpoint(instance_id: i32, url: []const u8, line: i32) u32 {
    return setBreakpointEx(instance_id, url, line, 0, false, "");
}

pub fn setBreakpointEx(
    instance_id: i32,
    url: []const u8,
    line: i32,
    column: i32,
    url_is_regex: bool,
    condition: []const u8,
) u32 {
    if (line <= 0 or url.len == 0) return 0;
    const binding = lookup(instance_id) orelse return 0;
    const copy = std.heap.c_allocator.dupe(u8, url) catch return 0;
    const cond = std.heap.c_allocator.dupe(u8, condition) catch {
        std.heap.c_allocator.free(copy);
        return 0;
    };
    const col: i32 = if (column < 0) 0 else column;
    binding.mutex.lock();
    const id = binding.next_breakpoint_id;
    binding.next_breakpoint_id += 1;
    binding.breakpoints.append(std.heap.c_allocator, .{
        .id = id,
        .url = copy,
        .line = line,
        .column = col,
        .url_is_regex = url_is_regex,
        .condition = cond,
    }) catch {
        binding.mutex.unlock();
        std.heap.c_allocator.free(copy);
        std.heap.c_allocator.free(cond);
        return 0;
    };
    binding.mutex.unlock();
    return id;
}

pub fn setBlackboxPatterns(instance_id: i32, patterns: []const []const u8) void {
    const binding = lookup(instance_id) orelse return;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    for (binding.blackbox.items) |pat| std.heap.c_allocator.free(pat);
    binding.blackbox.clearRetainingCapacity();
    for (patterns) |pat| {
        const copy = std.heap.c_allocator.dupe(u8, pat) catch continue;
        binding.blackbox.append(std.heap.c_allocator, copy) catch {
            std.heap.c_allocator.free(copy);
        };
    }
}

pub fn removeBreakpoint(instance_id: i32, id: u32) bool {
    const binding = lookup(instance_id) orelse return false;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    for (binding.breakpoints.items, 0..) |bp, i| {
        if (bp.id != id) continue;
        std.heap.c_allocator.free(bp.url);
        if (bp.condition.len > 0) std.heap.c_allocator.free(bp.condition);
        _ = binding.breakpoints.swapRemove(i);
        return true;
    }
    return false;
}

pub fn resumeExecution(instance_id: i32) void {
    continueWith(instance_id, .run);
}

pub fn stepIn(instance_id: i32) void {
    continueWith(instance_id, .step_in);
}

pub fn stepOver(instance_id: i32) void {
    continueWith(instance_id, .step_over);
}

pub fn stepOut(instance_id: i32) void {
    continueWith(instance_id, .step_out);
}

pub fn isPaused(instance_id: i32) bool {
    const binding = lookup(instance_id) orelse return false;
    return binding.pause.load(.seq_cst) != 0;
}

pub fn pausedLine(instance_id: i32) i32 {
    const binding = lookup(instance_id) orelse return 0;
    return binding.paused_line.load(.seq_cst);
}

pub fn pausedReason(instance_id: i32) PauseReason {
    const binding = lookup(instance_id) orelse return .breakpoint;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    return binding.paused_reason;
}

pub fn noteScript(instance_id: i32, url: []const u8, source: []const u8) void {
    if (comptime !@import("build_options").inspector) return;
    const binding = lookup(instance_id) orelse return;
    if (!binding.armed.load(.seq_cst)) return;
    // This may prewarm the bounded source journal, but native locations and frames resolve only through evaluator-assigned tags.
    _ = registerScript(instance_id, url, source);
}

fn registerScript(instance_id: i32, url: []const u8, source: []const u8) u32 {
    const binding = lookup(instance_id) orelse return 0;
    if (url.len == 0) return 0;
    const map_text = sourceMapUrl(source);
    const ends = scriptEnd(source);
    var published: ?ScriptInfo = null;
    binding.mutex.lock();
    const note_generation = binding.next_note_generation;
    if (note_generation == 0) {
        binding.mutex.unlock();
        return 0;
    }
    binding.next_note_generation +%= 1;
    for (binding.scripts.items) |*script| {
        if (std.mem.eql(u8, script.url, url) and std.mem.eql(u8, script.source, source)) {
            binding.active_script_id = script.id;
            script.last_note_generation = note_generation;
            const id = script.id;
            binding.mutex.unlock();
            return id;
        }
    }
    const id = binding.next_script_id;
    if (id == 0) {
        binding.mutex.unlock();
        return 0;
    }
    binding.next_script_id +%= 1;
    const url_copy = std.heap.c_allocator.dupe(u8, url) catch {
        binding.mutex.unlock();
        return 0;
    };
    const source_copy = std.heap.c_allocator.dupe(u8, source) catch {
        std.heap.c_allocator.free(url_copy);
        binding.mutex.unlock();
        return 0;
    };
    const map_copy = std.heap.c_allocator.dupe(u8, map_text) catch {
        std.heap.c_allocator.free(url_copy);
        std.heap.c_allocator.free(source_copy);
        binding.mutex.unlock();
        return 0;
    };
    var stored = Script{ .id = id, .url = url_copy, .source = source_copy, .end_line = ends.line, .end_column = ends.column, .hash = undefined, .source_map_url = map_copy, .last_note_generation = note_generation };
    formatHash(source, &stored.hash);
    binding.scripts.append(std.heap.c_allocator, stored) catch {
        freeScript(stored);
        binding.mutex.unlock();
        return 0;
    };
    binding.active_script_id = id;
    binding.script_bytes += scriptStorageBytes(stored);
    // Stable front eviction: free a prefix once, then compact remaining scripts in place.
    var remove_count: usize = 0;
    var retained_bytes = binding.script_bytes;
    while (binding.scripts.items.len - remove_count > 1 and
        (binding.scripts.items.len - remove_count > max_retained_scripts or retained_bytes > max_retained_source_bytes))
    {
        retained_bytes -= scriptStorageBytes(binding.scripts.items[remove_count]);
        remove_count += 1;
    }
    if (remove_count != 0) {
        for (binding.scripts.items[0..remove_count]) |evicted| freeScript(evicted);
        const remain = binding.scripts.items[remove_count..];
        var write: usize = 0;
        while (write < remain.len) : (write += 1) {
            binding.scripts.items[write] = remain[write];
        }
        binding.scripts.shrinkRetainingCapacity(remain.len);
        binding.script_bytes = retained_bytes;
    }
    published = cloneScriptInfo(std.heap.c_allocator, binding.scripts.items[binding.scripts.items.len - 1]) catch null;
    binding.mutex.unlock();
    if (published) |info| {
        defer freeScriptInfo(info);
        if (script_hook.load(.seq_cst)) |hook| hook(instance_id, info);
    }
    return id;
}

/// Latest script id registered for `url`, or 0 when the url is unknown.
pub fn scriptIdForUrl(instance_id: i32, url: []const u8) u32 {
    const binding = lookup(instance_id) orelse return 0;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    var index = binding.scripts.items.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, binding.scripts.items[index].url, url)) return binding.scripts.items[index].id;
    }
    return 0;
}

/// Resolves an evaluator-provided compilation tag. Unlike URL lookup this never guesses after a journal eviction or a tag from another unit.
pub fn scriptIdForTag(instance_id: i32, tag: u64) u32 {
    if (tag == 0 or tag > std.math.maxInt(u32)) return 0;
    const binding = lookup(instance_id) orelse return 0;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    return if (scriptByIdLocked(binding, @intCast(tag))) |script| script.id else 0;
}

/// Returns an independently owned snapshot. Release with freeScriptSnapshot.
pub fn snapshotScripts(instance_id: i32) []ScriptInfo {
    const binding = lookup(instance_id) orelse return &.{};
    binding.mutex.lock();
    defer binding.mutex.unlock();
    if (binding.scripts.items.len == 0) return &.{};
    const out = std.heap.c_allocator.alloc(ScriptInfo, binding.scripts.items.len) catch return &.{};
    for (binding.scripts.items, 0..) |script, i| {
        out[i] = cloneScriptInfo(std.heap.c_allocator, script) catch {
            for (out[0..i]) |info| freeScriptInfo(info);
            std.heap.c_allocator.free(out);
            return &.{};
        };
    }
    return out;
}

/// Returns an independently owned script. Release with freeScriptInfo.
pub fn scriptById(instance_id: i32, id: u32) ?ScriptInfo {
    const binding = lookup(instance_id) orelse return null;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    for (binding.scripts.items) |script| {
        if (script.id != id) continue;
        return cloneScriptInfo(std.heap.c_allocator, script) catch null;
    }
    return null;
}

pub fn freeScriptInfo(info: ScriptInfo) void {
    freeScriptInfoWithAllocator(std.heap.c_allocator, info);
}

pub fn freeScriptSnapshot(scripts: []ScriptInfo) void {
    for (scripts) |script| freeScriptInfo(script);
    if (scripts.len != 0) std.heap.c_allocator.free(scripts);
}

/// Locations use 1-based lines and a 0 column. The caller frees the slice.
pub fn locationsFor(instance_id: i32, url: []const u8, line: i32) []BreakLocation {
    const binding = lookup(instance_id) orelse return &.{};
    binding.mutex.lock();
    defer binding.mutex.unlock();
    var breakpoint_id: u32 = 0;
    for (binding.breakpoints.items) |bp| {
        if (bp.line == line and std.mem.eql(u8, bp.url, url)) {
            breakpoint_id = bp.id;
            break;
        }
    }
    if (breakpoint_id == 0) return &.{};
    var list: std.ArrayList(BreakLocation) = .empty;
    for (binding.scripts.items) |script| {
        if (!std.mem.eql(u8, script.url, url)) continue;
        if (line - 1 > script.end_line) continue;
        list.append(std.heap.c_allocator, .{
            .breakpoint_id = breakpoint_id,
            .script_id = script.id,
            .line = line,
            .column = 0,
        }) catch {};
    }
    return list.toOwnedSlice(std.heap.c_allocator) catch &.{};
}

/// Breakpoints that match this script's url and fall on a real line. The caller frees the slice.
pub fn breakpointsOnScript(instance_id: i32, script_id: u32) []BreakLocation {
    const binding = lookup(instance_id) orelse return &.{};
    binding.mutex.lock();
    defer binding.mutex.unlock();
    var found: ?Script = null;
    for (binding.scripts.items) |script| {
        if (script.id == script_id) {
            found = script;
            break;
        }
    }
    const script = found orelse return &.{};
    var list: std.ArrayList(BreakLocation) = .empty;
    for (binding.breakpoints.items) |bp| {
        if (!urlPatternMatch(bp, script.url)) continue;
        if (bp.line - 1 > script.end_line) continue;
        const column = firstBreakColumn(script.source, bp.line, bp.column) orelse continue;
        list.append(std.heap.c_allocator, .{
            .breakpoint_id = bp.id,
            .script_id = script.id,
            .line = bp.line,
            .column = column,
        }) catch {};
    }
    return list.toOwnedSlice(std.heap.c_allocator) catch &.{};
}

/// Locations for one breakpoint. Column is the first breakable column. The caller frees the slice.
pub fn locationsForId(instance_id: i32, id: u32) []BreakLocation {
    const binding = lookup(instance_id) orelse return &.{};
    binding.mutex.lock();
    defer binding.mutex.unlock();
    var found: ?Breakpoint = null;
    for (binding.breakpoints.items) |bp| {
        if (bp.id == id) {
            found = bp;
            break;
        }
    }
    const bp = found orelse return &.{};
    var list: std.ArrayList(BreakLocation) = .empty;
    for (binding.scripts.items) |script| {
        if (!urlPatternMatch(bp, script.url)) continue;
        if (bp.line - 1 > script.end_line) continue;
        const column = firstBreakColumn(script.source, bp.line, bp.column) orelse continue;
        list.append(std.heap.c_allocator, .{
            .breakpoint_id = bp.id,
            .script_id = script.id,
            .line = bp.line,
            .column = column,
        }) catch {};
    }
    return list.toOwnedSlice(std.heap.c_allocator) catch &.{};
}

/// Returns exact bytecode locations captured while this script was evaluated. `start` is inclusive and `end` is exclusive, with CDP's zero-based source coordinates. `restrictToFunction` is intentionally rejected by the CDP adapter because QuickJS-NG does not expose a stable function-range identity.
pub fn possibleBreakpoints(
    instance_id: i32,
    script_id: u32,
    start_line0: i32,
    start_column0: i32,
    end_line0: i32,
    end_column0: i32,
) PossibleBreakpointsError![]BreakLocation {
    const binding = lookup(instance_id) orelse return error.ScriptUnknown;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    for (binding.scripts.items) |script| {
        if (script.id != script_id) continue;
        if (script.break_locations_truncated) return error.LocationsTruncated;
        if (!script.break_locations_collected) return error.LocationsUnavailable;
        var list: std.ArrayList(BreakLocation) = .empty;
        for (script.break_locations.items) |location| {
            const line0 = location.line - 1;
            const column0 = location.column;
            if (!locationInRange(line0, column0, start_line0, start_column0, end_line0, end_column0)) continue;
            list.append(std.heap.c_allocator, .{
                .breakpoint_id = 0,
                .script_id = script.id,
                .line = location.line,
                .column = location.column,
            }) catch {
                list.deinit(std.heap.c_allocator);
                return error.LocationsUnavailable;
            };
        }
        return list.toOwnedSlice(std.heap.c_allocator) catch error.LocationsUnavailable;
    }
    return error.ScriptUnknown;
}

fn locationInRange(line0: i32, column0: i32, start_line0: i32, start_column0: i32, end_line0: i32, end_column0: i32) bool {
    if (line0 < start_line0 or (line0 == start_line0 and column0 < start_column0)) return false;
    if (line0 > end_line0 or (line0 == end_line0 and column0 >= end_column0)) return false;
    return true;
}

/// Innermost frame first. Line is 1-based and column is 0-based. Caller frees each name and url, then the slice. Engine thread only, while paused.
pub fn copyDebugStack(instance_id: i32) []DebugFrame {
    if (comptime !@import("build_options").inspector) return &.{};
    if (comptime backend.active_backend == .jsc) {
        const parsed = @import("../backend/jsc/backtrace.zig").copyStack(instance_id);
        defer if (parsed.len != 0) std.heap.c_allocator.free(parsed);
        if (parsed.len == 0) return &.{};
        const out = std.heap.c_allocator.alloc(DebugFrame, parsed.len) catch return &.{};
        for (parsed, 0..) |frame, i| {
            out[i] = .{
                .name = frame.name,
                .url = frame.url,
                .line = frame.line,
                .column = frame.column,
            };
        }
        return out;
    }
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return &.{};
    const ctx = engine.getContext(instance_id) orelse return &.{};
    const qjs = @import("../backend.zig").ActiveEngineModule.c_api.qjs;
    var raw: [64]qjs.JSDebugFrameInfo = undefined;
    const n = qjs.JS_CopyDebugStack(ctx, &raw, raw.len);
    if (n <= 0) return &.{};
    const count: usize = @intCast(n);
    const out = std.heap.c_allocator.alloc(DebugFrame, count) catch return &.{};
    for (raw[0..count], 0..) |frame, i| {
        const name = std.mem.sliceTo(&frame.name, 0);
        const url = std.mem.sliceTo(&frame.filename, 0);
        const column: i32 = if (frame.column > 0) frame.column - 1 else 0;
        out[i] = .{
            .name = std.heap.c_allocator.dupe(u8, name) catch &.{},
            .url = std.heap.c_allocator.dupe(u8, url) catch &.{},
            .line = frame.line,
            .column = column,
            .script_tag = if (comptime backend.active_backend == .quickjs_ng) frame.script_tag else 0,
        };
    }
    return out;
}

/// Caller-owned storage for one stack frame. `writeDebugStack` fills `name_len` / `url_len` and does not allocate.
pub const StackFrameBuf = struct {
    name: []u8,
    url: []u8,
    name_len: usize = 0,
    url_len: usize = 0,
    line: i32 = 0,
    column: i32 = 0,
    script_tag: u64 = 0,
};

/// Innermost frame first. Line is 1-based and column is 0-based, matching `copyDebugStack`. Copies into `out` and does not allocate. At most 16 frames are copied. Engine thread only.
pub fn writeDebugStack(instance_id: i32, out: []StackFrameBuf) usize {
    if (comptime !@import("build_options").inspector) return 0;
    if (out.len == 0) return 0;
    if (comptime backend.active_backend == .jsc) {
        return @import("../backend/jsc/backtrace.zig").writeStack(instance_id, out);
    }
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return 0;
    const ctx = engine.getContext(instance_id) orelse return 0;
    const qjs = @import("../backend.zig").ActiveEngineModule.c_api.qjs;
    var raw: [16]qjs.JSDebugFrameInfo = undefined;
    const max_n: usize = @min(out.len, raw.len);
    const n = qjs.JS_CopyDebugStack(ctx, &raw, @intCast(max_n));
    if (n <= 0) return 0;
    const count: usize = @min(@as(usize, @intCast(n)), max_n);
    for (raw[0..count], out[0..count]) |frame, *dst| {
        const name = std.mem.sliceTo(&frame.name, 0);
        const url = std.mem.sliceTo(&frame.filename, 0);
        const name_len = @min(name.len, dst.name.len);
        const url_len = @min(url.len, dst.url.len);
        if (name_len != 0) @memcpy(dst.name[0..name_len], name[0..name_len]);
        if (url_len != 0) @memcpy(dst.url[0..url_len], url[0..url_len]);
        dst.name_len = name_len;
        dst.url_len = url_len;
        dst.line = frame.line;
        dst.column = if (frame.column > 0) frame.column - 1 else 0;
        dst.script_tag = if (comptime backend.active_backend == .quickjs_ng) frame.script_tag else 0;
    }
    return count;
}

/// The receiver of a paused frame, when it is an object. Caller frees it. Engine thread only, while paused.
pub fn copyDebugThis(instance_id: i32, frame_index: i32) ?backend.ActiveEngine.Value {
    if (comptime !@import("build_options").inspector) return null;
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return null;
    const ctx = engine.getContext(instance_id) orelse return null;
    const c_api = @import("../backend.zig").ActiveEngineModule.c_api;
    const qjs = c_api.qjs;
    const local = qjs.JS_CopyDebugScope(ctx, frame_index, 0);
    if (local.tag == @import("../backend.zig").ActiveEngineModule.qjs.JS_TAG_EXCEPTION) return null;
    defer backend.ActiveEngine.freeValue(ctx, local);
    const this_val = qjs.JS_GetPropertyStr(ctx, local, "this");
    if (c_api.jsIsException(this_val) or c_api.jsIsUndefined(this_val) or c_api.jsbay_qjs_JS_IsObject(this_val) == 0) {
        backend.ActiveEngine.freeValue(ctx, this_val);
        return null;
    }
    return this_val;
}

pub fn copyDebugScope(instance_id: i32, frame_index: i32, scope: u8) ?backend.ActiveEngine.Value {
    if (comptime !@import("build_options").inspector) return null;
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return null;
    const ctx = engine.getContext(instance_id) orelse return null;
    const qjs = @import("../backend.zig").ActiveEngineModule.c_api.qjs;
    const value = qjs.JS_CopyDebugScope(ctx, frame_index, scope);
    if (value.tag == @import("../backend.zig").ActiveEngineModule.qjs.JS_TAG_EXCEPTION) return null;
    return value;
}

pub const FrameEval = struct {
    ok: bool,
    text: []u8,
};

/// Evaluate `expr` in a paused frame. Caller frees `text`. Engine thread only.
pub fn evalDebugFrame(instance_id: i32, frame_index: i32, expr: []const u8) FrameEval {
    if (comptime !@import("build_options").inspector) return .{ .ok = false, .text = &.{} };
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return .{ .ok = false, .text = &.{} };
    const ctx = engine.getContext(instance_id) orelse return .{ .ok = false, .text = &.{} };
    const qjs = @import("../backend.zig").ActiveEngineModule.c_api.qjs;
    const ActiveEngine = backend.ActiveEngine;
    const value = qjs.JS_EvalInDebugFrame(ctx, frame_index, expr.ptr, expr.len);
    if (value.tag == @import("../backend.zig").ActiveEngineModule.qjs.JS_TAG_EXCEPTION) {
        const thrown = qjs.JS_GetException(ctx);
        const text = ActiveEngine.valueToString(ctx, thrown) orelse
            std.heap.c_allocator.dupe(u8, "exception") catch &.{};
        ActiveEngine.freeValue(ctx, thrown);
        return .{ .ok = false, .text = @constCast(text) };
    }
    const text = ActiveEngine.valueToString(ctx, value) orelse
        std.heap.c_allocator.dupe(u8, "") catch &.{};
    ActiveEngine.freeValue(ctx, value);
    return .{ .ok = true, .text = @constCast(text) };
}

fn continueWith(instance_id: i32, mode: StepMode) void {
    const binding = lookup(instance_id) orelse return;
    binding.mutex.lock();
    binding.mode = mode;
    const n = binding.paused_url_len;
    if (n > 0) @memcpy(binding.skip_url[0..n], binding.paused_url[0..n]);
    binding.skip_url_len = n;
    binding.skip_script_tag = binding.paused_script_tag;
    binding.skip_line = binding.paused_line.load(.seq_cst);
    binding.skip_depth = binding.paused_depth;
    binding.skip_seen_same = false;
    binding.skip_saw_deeper = false;
    binding.mutex.unlock();
    binding.pause.store(0, .seq_cst);
}

fn finishStepOut(binding: *Binding, url: []const u8, line: i32, depth: i32, script_tag: u64) bool {
    binding.mutex.lock();
    defer binding.mutex.unlock();
    if (binding.mode != .step_out or depth >= binding.paused_depth) return false;
    // The callee returned to the call expression. Step over that line so the pause lands on the caller's next statement.
    const n = @min(url.len, binding.skip_url.len);
    if (n > 0) @memcpy(binding.skip_url[0..n], url[0..n]);
    binding.skip_url_len = n;
    binding.skip_script_tag = script_tag;
    binding.skip_line = line;
    binding.skip_depth = depth;
    binding.skip_seen_same = true;
    binding.skip_saw_deeper = false;
    binding.mode = .step_over;
    binding.paused_depth = depth;
    return true;
}

fn consumeSkip(binding: *Binding, url: []const u8, line: i32, depth: i32, script_tag: u64) bool {
    binding.mutex.lock();
    defer binding.mutex.unlock();
    if (binding.skip_line < 0) return false;
    const same = binding.skip_script_tag == script_tag and binding.skip_line == line and binding.skip_depth == depth and
        binding.skip_url_len == url.len and
        std.mem.eql(u8, binding.skip_url[0..binding.skip_url_len], url);
    if (same) {
        if (binding.skip_saw_deeper) {
            // The call we stepped over returned to its own line.
            binding.skip_line = -1;
            binding.skip_url_len = 0;
            binding.skip_script_tag = 0;
            return true;
        }
        if (!binding.skip_seen_same) {
            binding.skip_seen_same = true;
            return true;
        }
        binding.skip_line = -1;
        binding.skip_url_len = 0;
        binding.skip_script_tag = 0;
        return false;
    }
    if (depth > binding.skip_depth) {
        binding.skip_saw_deeper = true;
        return false;
    }
    binding.skip_line = -1;
    binding.skip_url_len = 0;
    binding.skip_script_tag = 0;
    return false;
}

fn lookup(instance_id: i32) ?*Binding {
    table_mutex.lock();
    defer table_mutex.unlock();
    const map = table orelse return null;
    return map.get(instance_id);
}

/// Locks a binding while it is still pinned by the table. Callers release `binding.mutex`; detach takes the same table-then-binding order before it can remove and free the record.
fn lockBinding(instance_id: i32) ?*Binding {
    table_mutex.lock();
    const map = table orelse {
        table_mutex.unlock();
        return null;
    };
    const binding = map.get(instance_id) orelse {
        table_mutex.unlock();
        return null;
    };
    binding.mutex.lock();
    table_mutex.unlock();
    return binding;
}

fn arm(binding: *Binding) void {
    if (comptime !@import("build_options").inspector) return;
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    if (binding.armed.load(.seq_cst)) return;
    const rt = binding.runtime orelse return;
    const qjs = @import("../backend.zig").ActiveEngineModule.c_api.qjs;
    qjs.JS_SetLocationHandler(@ptrCast(rt), @ptrCast(&locationTrampoline), binding);
    if (comptime backend.active_backend == .quickjs_ng) {
        qjs.JS_SetScriptTagHandler(@ptrCast(rt), @ptrCast(&scriptTagTrampoline), binding);
        qjs.JS_SetBreakLocationHandler(@ptrCast(rt), @ptrCast(&breakLocationTrampoline), binding);
    }
    qjs.JS_SetExceptionHandler(@ptrCast(rt), @ptrCast(&exceptionTrampoline), binding);
    qjs.JS_SetDebuggerHandler(@ptrCast(rt), @ptrCast(&debuggerTrampoline), binding);
    binding.handler_install_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
    binding.armed.store(true, .seq_cst);
}

fn disarm(binding: *Binding) void {
    if (comptime !@import("build_options").inspector) return;
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    if (!binding.armed.swap(false, .seq_cst)) return;
    const rt = binding.runtime orelse return;
    const qjs = @import("../backend.zig").ActiveEngineModule.c_api.qjs;
    qjs.JS_SetLocationHandler(@ptrCast(rt), null, null);
    if (comptime backend.active_backend == .quickjs_ng) {
        qjs.JS_SetScriptTagHandler(@ptrCast(rt), null, null);
        qjs.JS_SetBreakLocationHandler(@ptrCast(rt), null, null);
    }
    qjs.JS_SetExceptionHandler(@ptrCast(rt), null, null);
    qjs.JS_SetDebuggerHandler(@ptrCast(rt), null, null);
    binding.handler_install_thread_id.store(0, .seq_cst);
}

fn destroyBinding(binding: *Binding) void {
    for (binding.breakpoints.items) |bp| {
        std.heap.c_allocator.free(bp.url);
        if (bp.condition.len > 0) std.heap.c_allocator.free(bp.condition);
    }
    binding.breakpoints.deinit(std.heap.c_allocator);
    for (binding.blackbox.items) |pat| std.heap.c_allocator.free(pat);
    binding.blackbox.deinit(std.heap.c_allocator);
    for (binding.scripts.items) |script| {
        freeScript(script);
    }
    binding.scripts.deinit(std.heap.c_allocator);
    binding.mutex.deinit();
    std.heap.c_allocator.destroy(binding);
}

fn scriptStorageBytes(script: Script) usize {
    return script.url.len + script.source.len + script.hash.len + script.source_map_url.len;
}

fn freeScript(script: Script) void {
    std.heap.c_allocator.free(script.url);
    std.heap.c_allocator.free(script.source);
    std.heap.c_allocator.free(script.source_map_url);
    var owned = script;
    owned.break_locations.deinit(std.heap.c_allocator);
}

fn cloneScriptInfo(allocator: std.mem.Allocator, script: Script) !ScriptInfo {
    const url = try allocator.dupe(u8, script.url);
    errdefer allocator.free(url);
    const source = try allocator.dupe(u8, script.source);
    errdefer allocator.free(source);
    const hash = try allocator.dupe(u8, &script.hash);
    errdefer allocator.free(hash);
    const source_map_url = try allocator.dupe(u8, script.source_map_url);
    return .{
        .id = script.id,
        .url = url,
        .source = source,
        .end_line = script.end_line,
        .end_column = script.end_column,
        .hash = hash,
        .source_map_url = source_map_url,
    };
}

fn freeScriptInfoWithAllocator(allocator: std.mem.Allocator, info: ScriptInfo) void {
    allocator.free(@constCast(info.url));
    allocator.free(@constCast(info.source));
    allocator.free(@constCast(info.hash));
    allocator.free(@constCast(info.source_map_url));
}

test "debugger: script info clone releases every partial allocation on OOM" {
    var url = [_]u8{ 'o', 'o', 'm', '.', 'j', 's' };
    var source = [_]u8{ 'l', 'e', 't', ' ', 'a', 'n', 's', 'w', 'e', 'r', ' ', '=', ' ', '4', '2', ';' };
    var source_map_url = [_]u8{ 'o', 'o', 'm', '.', 'j', 's', '.', 'm', 'a', 'p' };
    var script = Script{
        .id = 1,
        .url = &url,
        .source = &source,
        .end_line = 0,
        .end_column = 16,
        .hash = undefined,
        .source_map_url = &source_map_url,
    };
    formatHash(script.source, &script.hash);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, input: Script) !void {
            const info = try cloneScriptInfo(allocator, input);
            defer freeScriptInfoWithAllocator(allocator, info);
        }
    }.run, .{script});
}

fn shouldPause(binding: *Binding, url: []const u8, line: i32, depth: i32, script_tag: u64) ?PauseReason {
    return breakpointHit(binding, url, line, depth, script_tag);
}

fn breakpointHit(binding: *Binding, url: []const u8, line: i32, depth: i32, script_tag: u64) ?PauseReason {
    binding.mutex.lock();
    if (binding.break_requested.swap(0, .seq_cst) != 0) {
        binding.mutex.unlock();
        return .other;
    }
    const stepped = switch (binding.mode) {
        .step_in => true,
        .step_over => depth <= binding.paused_depth,
        .step_out => depth < binding.paused_depth,
        .run => false,
    };
    if (stepped) {
        binding.mutex.unlock();
        return .step;
    }
    if (binding.breakpoints_active.load(.seq_cst) == 0) {
        binding.mutex.unlock();
        return null;
    }
    var index: usize = 0;
    while (index < binding.breakpoints.items.len) : (index += 1) {
        const bp = binding.breakpoints.items[index];
        if (bp.line != line or !urlPatternMatch(bp, url)) continue;
        if (scriptByTagLocked(binding, script_tag)) |script| {
            if (firstBreakColumn(script.source, line, bp.column) == null) continue;
        }
        const cond = std.heap.c_allocator.dupe(u8, bp.condition) catch continue;
        binding.mutex.unlock();
        const ok = cond.len == 0 or conditionPasses(binding, cond);
        if (cond.len > 0) std.heap.c_allocator.free(cond);
        if (ok) return .breakpoint;
        binding.mutex.lock();
    }
    binding.mutex.unlock();
    return null;
}

fn scriptByUrlLocked(binding: *Binding, url: []const u8) ?Script {
    var found: ?Script = null;
    for (binding.scripts.items) |script| {
        if (std.mem.eql(u8, script.url, url)) found = script;
    }
    return found;
}

fn urlPatternMatch(bp: Breakpoint, url: []const u8) bool {
    if (bp.url_is_regex) return regexSearch(bp.url, url);
    return std.mem.eql(u8, bp.url, url);
}

fn isBlackboxed(binding: *Binding, url: []const u8) bool {
    binding.mutex.lock();
    var copies: std.ArrayList([]u8) = .empty;
    for (binding.blackbox.items) |pat| {
        const copy = std.heap.c_allocator.dupe(u8, pat) catch continue;
        copies.append(std.heap.c_allocator, copy) catch std.heap.c_allocator.free(copy);
    }
    binding.mutex.unlock();
    defer {
        for (copies.items) |pat| std.heap.c_allocator.free(pat);
        copies.deinit(std.heap.c_allocator);
    }
    for (copies.items) |pat| {
        if (regexSearch(pat, url)) return true;
    }
    return false;
}

fn conditionPasses(binding: *Binding, expr: []const u8) bool {
    binding.suppress.store(1, .seq_cst);
    defer binding.suppress.store(0, .seq_cst);
    const wrapped = std.fmt.allocPrint(std.heap.c_allocator, "!!({s})", .{expr}) catch return false;
    defer std.heap.c_allocator.free(wrapped);
    const result = evalDebugFrame(binding.instance_id, 0, wrapped);
    defer if (result.text.len > 0) std.heap.c_allocator.free(result.text);
    return result.ok and std.mem.eql(u8, result.text, "true");
}

fn firstBreakColumn(source: []const u8, line: i32, requested: i32) ?i32 {
    if (line <= 0) return null;
    var current: i32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            if (current == line) return columnOnLine(source[start..i], requested);
            current += 1;
            start = i + 1;
        }
    }
    return null;
}

fn columnOnLine(line_text: []const u8, requested: i32) ?i32 {
    var col: i32 = 0;
    for (line_text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and col >= requested) return col;
        col += 1;
    }
    return null;
}

const Atom = struct { any: bool, ch: u8, rest: []const u8 };

fn nextAtom(pat: []const u8) ?Atom {
    if (pat.len == 0) return null;
    if (pat[0] == '\\' and pat.len >= 2) return .{ .any = false, .ch = pat[1], .rest = pat[2..] };
    if (pat[0] == '.') return .{ .any = true, .ch = 0, .rest = pat[1..] };
    return .{ .any = false, .ch = pat[0], .rest = pat[1..] };
}

fn atomMatches(atom: Atom, text: []const u8) bool {
    if (text.len == 0) return false;
    return atom.any or text[0] == atom.ch;
}

fn regexSearch(pattern: []const u8, text: []const u8) bool {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= pattern.len) : (i += 1) {
        const split = i == pattern.len or (pattern[i] == '|' and (i == 0 or pattern[i - 1] != '\\'));
        if (!split) continue;
        if (matchAlt(pattern[start..i], text)) return true;
        start = i + 1;
    }
    return false;
}

fn matchAlt(pat: []const u8, text: []const u8) bool {
    if (pat.len > 0 and pat[0] == '^') return matchHere(pat[1..], text);
    var i: usize = 0;
    while (true) : (i += 1) {
        if (matchHere(pat, text[i..])) return true;
        if (i == text.len) return false;
    }
}

fn matchHere(pat: []const u8, text: []const u8) bool {
    if (pat.len == 0) return true;
    if (pat[0] == '$' and pat.len == 1) return text.len == 0;
    const atom = nextAtom(pat) orelse return false;
    if (atom.rest.len > 0 and atom.rest[0] == '*') return matchStar(atom, atom.rest[1..], text);
    if (atom.rest.len > 0 and atom.rest[0] == '+') {
        if (!atomMatches(atom, text)) return false;
        return matchStar(atom, atom.rest[1..], text[1..]);
    }
    if (atom.rest.len > 0 and atom.rest[0] == '?') {
        if (matchHere(atom.rest[1..], text)) return true;
        if (!atomMatches(atom, text)) return false;
        return matchHere(atom.rest[1..], text[1..]);
    }
    if (!atomMatches(atom, text)) return false;
    return matchHere(atom.rest, text[1..]);
}

fn matchStar(atom: Atom, rest: []const u8, text: []const u8) bool {
    var t = text;
    while (true) {
        if (matchHere(rest, t)) return true;
        if (!atomMatches(atom, t)) return false;
        t = t[1..];
    }
}

fn pauseColumn(binding: *Binding, url: []const u8, line: i32, hook_column: i32, script_tag: u64) i32 {
    binding.mutex.lock();
    defer binding.mutex.unlock();
    for (binding.breakpoints.items) |bp| {
        if (bp.line != line or !urlPatternMatch(bp, url)) continue;
        const script = scriptByTagLocked(binding, script_tag) orelse return hook_column;
        return firstBreakColumn(script.source, line, bp.column) orelse hook_column;
    }
    return hook_column;
}

/// Runs after an NG compilation unit is complete but before it can execute. Returning the retained journal id makes the native bytecode tag stable for its lifetime; a failed allocation deliberately returns zero (unknown).
fn scriptTagTrampoline(
    _: ?*anyopaque,
    filename: [*c]const u8,
    source: [*c]const u8,
    source_len: usize,
    opaque_ptr: ?*anyopaque,
) callconv(.c) u64 {
    const binding: *Binding = @ptrCast(@alignCast(opaque_ptr orelse return 0));
    if (binding.alive.load(.seq_cst) == 0 or filename == null or source == null) return 0;
    const url = std.mem.span(filename);
    if (url.len == 0) return 0;
    const text = source[0..source_len];
    return registerScript(binding.instance_id, url, text);
}

/// Called by the QuickJS-NG evaluator before it releases the top-level bytecode. It only copies source metadata into the bounded journal; it must not execute JavaScript or take ownership of engine values.
fn breakLocationTrampoline(
    _: ?*anyopaque,
    filename: [*c]const u8,
    line: c_int,
    column: c_int,
    script_tag: u64,
    complete: c_int,
    truncated: c_int,
    opaque_ptr: ?*anyopaque,
) callconv(.c) void {
    const binding: *Binding = @ptrCast(@alignCast(opaque_ptr orelse return));
    if (binding.alive.load(.seq_cst) == 0) return;
    binding.mutex.lock();
    defer binding.mutex.unlock();
    if (complete != 0) {
        const script = scriptByTagLocked(binding, script_tag) orelse return;
        script.break_locations_collected = true;
        script.break_locations_truncated = truncated != 0;
        return;
    }
    _ = filename;
    const script = scriptByTagLocked(binding, script_tag) orelse return;
    if (line <= 0 or script.break_locations_truncated) return;
    if (script.break_locations_collected) {
        script.break_locations.clearRetainingCapacity();
        script.break_locations_collected = false;
    }
    const column0: i32 = if (column > 0) column - 1 else 0;
    if (script.break_locations.items.len > 0) {
        const last = script.break_locations.items[script.break_locations.items.len - 1];
        if (last.line == line and last.column == column0) return;
    }
    script.break_locations.append(std.heap.c_allocator, .{ .line = line, .column = column0 }) catch {
        script.break_locations_truncated = true;
    };
}

fn scriptByIdLocked(binding: *Binding, id: u32) ?*Script {
    if (id == 0) return null;
    for (binding.scripts.items) |*script| {
        if (script.id == id) return script;
    }
    return null;
}

fn scriptByTagLocked(binding: *Binding, tag: u64) ?*Script {
    if (tag == 0 or tag > std.math.maxInt(u32)) return null;
    return scriptByIdLocked(binding, @intCast(tag));
}

fn locationTrampoline(
    _: ?*anyopaque,
    filename: [*c]const u8,
    line: c_int,
    column: c_int,
    depth: c_int,
    script_tag: u64,
    opaque_ptr: ?*anyopaque,
) callconv(.c) void {
    const binding: *Binding = @ptrCast(@alignCast(opaque_ptr orelse return));
    if (binding.skip_all_pauses.load(.seq_cst) != 0) return;
    binding.exception_hold.store(0, .seq_cst);
    if (binding.suppress.load(.seq_cst) != 0) return;
    if (binding.alive.load(.seq_cst) == 0) return;
    const url = if (filename == null) "" else std.mem.span(filename);
    const explicit_pause = binding.break_requested.load(.seq_cst) != 0;
    if (!explicit_pause and consumeSkip(binding, url, line, depth, script_tag)) return;
    if (!explicit_pause and finishStepOut(binding, url, line, depth, script_tag)) return;
    if (!explicit_pause and isBlackboxed(binding, url)) return;
    const reason = shouldPause(binding, url, line, depth, script_tag) orelse return;
    const hook_column: i32 = if (column > 0) column - 1 else 0;
    const column0 = if (reason == .breakpoint) pauseColumn(binding, url, line, hook_column, script_tag) else hook_column;
    enterPause(binding, url, line, column0, depth, reason, script_tag);
}

fn exceptionTrampoline(
    _: ?*anyopaque,
    caught: c_int,
    opaque_ptr: ?*anyopaque,
) callconv(.c) void {
    const binding: *Binding = @ptrCast(@alignCast(opaque_ptr orelse return));
    if (binding.skip_all_pauses.load(.seq_cst) != 0) return;
    if (binding.suppress.load(.seq_cst) != 0) return;
    if (binding.alive.load(.seq_cst) == 0) return;
    if (binding.exception_hold.load(.seq_cst) != 0) return;
    const mode: ExceptionPause = @fromBackingInt(@intCast(binding.exception_mode.load(.seq_cst)));
    switch (mode) {
        .none => return,
        .uncaught => if (caught != 0) return,
        .all => {},
    }
    binding.exception_hold.store(1, .seq_cst);
    pauseAtTopFrame(binding, .exception);
}

fn debuggerTrampoline(_: ?*anyopaque, opaque_ptr: ?*anyopaque) callconv(.c) void {
    const binding: *Binding = @ptrCast(@alignCast(opaque_ptr orelse return));
    if (binding.skip_all_pauses.load(.seq_cst) != 0) return;
    if (binding.suppress.load(.seq_cst) != 0) return;
    if (binding.alive.load(.seq_cst) == 0) return;
    if (binding.break_on_debugger.load(.seq_cst) == 0) return;
    pauseAtTopFrame(binding, .other);
}

fn pauseAtTopFrame(binding: *Binding, reason: PauseReason) void {
    const stack = copyDebugStack(binding.instance_id);
    var url_buf: [512]u8 = undefined;
    var url_len: usize = 0;
    var line: i32 = 0;
    var column: i32 = 0;
    var depth: i32 = 0;
    var script_tag: u64 = 0;
    if (stack.len > 0) {
        const frame = stack[0];
        url_len = @min(frame.url.len, url_buf.len);
        if (url_len > 0) @memcpy(url_buf[0..url_len], frame.url[0..url_len]);
        line = frame.line;
        column = frame.column;
        depth = @intCast(stack.len);
        script_tag = frame.script_tag;
        for (stack) |item| {
            if (item.name.len > 0) std.heap.c_allocator.free(item.name);
            if (item.url.len > 0) std.heap.c_allocator.free(item.url);
        }
        std.heap.c_allocator.free(stack);
    }
    enterPause(binding, url_buf[0..url_len], line, column, depth, reason, script_tag);
}

fn enterPause(
    binding: *Binding,
    url: []const u8,
    line: i32,
    column: i32,
    depth: i32,
    reason: PauseReason,
    script_tag: u64,
) void {
    binding.mutex.lock();
    binding.mode = .run;
    binding.paused_depth = depth;
    binding.paused_reason = reason;
    binding.paused_script_tag = script_tag;
    const n = @min(url.len, binding.paused_url.len);
    if (n > 0) @memcpy(binding.paused_url[0..n], url[0..n]);
    binding.paused_url_len = n;
    binding.mutex.unlock();
    binding.paused_line.store(line, .seq_cst);
    binding.paused_column.store(column, .seq_cst);
    binding.pause.store(1, .seq_cst);
    binding.suppress.store(1, .seq_cst);

    if (pause_hook.load(.seq_cst)) |hook| {
        hook(binding.instance_id, .{
            .reason = reason,
            .line = line,
            .column = column,
            .url = binding.paused_url[0..binding.paused_url_len],
        });
    }

    while (binding.pause.load(.seq_cst) != 0 and binding.alive.load(.seq_cst) != 0) {
        _ = dispatch.drainPausedDebuggerControl(binding.instance_id);
        if (binding.pause.load(.seq_cst) == 0 or binding.alive.load(.seq_cst) == 0) break;
        io.sleepMs(1);
    }
    binding.suppress.store(0, .seq_cst);
}

fn scriptEnd(source: []const u8) struct { line: i32, column: i32 } {
    var line: i32 = 0;
    var column: i32 = 0;
    for (source) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn sourceMapUrl(source: []const u8) []const u8 {
    const marker = "sourceMappingURL=";
    const at = std.mem.lastIndexOf(u8, source, marker) orelse return "";
    var rest = source[at + marker.len ..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |end| rest = rest[0..end];
    if (std.mem.indexOfScalar(u8, rest, '\r')) |end| rest = rest[0..end];
    return std.mem.trim(u8, rest, " \t");
}

fn formatHash(source: []const u8, out: *[16]u8) void {
    var hash: u64 = 0xcbf29ce484222325;
    for (source) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    const hex = "0123456789abcdef";
    for (0..16) |i| {
        const shift: u6 = @intCast((15 - i) * 4);
        out[i] = hex[@as(usize, @intCast((hash >> shift) & 0xf))];
    }
}
