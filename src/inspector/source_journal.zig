//! Bounded source metadata and native location storage. No VM calls, hooks, or locks live here.
//!
//! The caller holds Binding's existing mutex for every Journal operation and borrowed Script view. This keeps breakpoint/source reads atomic together. Snapshots own their allocations; notifications are the caller's responsibility after unlocking.

const std = @import("std");

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

pub const Script = struct {
    id: u32,
    url: []u8,
    source: []u8,
    end_line: i32,
    end_column: i32,
    hash: [16]u8,
    source_map_url: []u8,
    // Journal storage is FIFO, but a source can be evaluated again after a newer revision with the same URL has been recorded.
    last_note_generation: u64 = 0,
    // Native bytecode locations are retained independently of source text, which cannot distinguish executable statements from comments or whitespace.
    break_locations: std.ArrayList(SourceLocation) = .empty,
    break_locations_collected: bool = false,
    break_locations_truncated: bool = false,
};

pub const SourceLocation = struct {
    line: i32,
    column: i32,
};

pub const Registration = struct { id: u32 = 0, published: ?ScriptInfo = null };

pub const PreparedSource = struct {
    url: []const u8,
    source: []const u8,
    source_map_url: []const u8,
    end: struct { line: i32, column: i32 },
};

/// Scan immutable source before acquiring the caller's mutex, without allocating.
pub fn prepare(url: []const u8, source: []const u8) PreparedSource {
    const end = scriptEnd(source);
    return .{ .url = url, .source = source, .source_map_url = sourceMapUrl(source), .end = .{ .line = end.line, .column = end.column } };
}

pub const Journal = struct {
    allocator: std.mem.Allocator,
    next_script_id: u32 = 1,
    next_note_generation: u64 = 1,
    scripts: std.ArrayList(Script) = .empty,
    script_bytes: usize = 0,
    active_script_id: u32 = 0,
    collecting_script_id: u32 = 0,

    pub fn registerLocked(self: *Journal, prepared: PreparedSource) Registration {
        const url = prepared.url;
        const source = prepared.source;
        if (url.len == 0) return .{};
        const map_text = prepared.source_map_url;
        const ends = prepared.end;
        const note_generation = self.next_note_generation;
        if (note_generation == 0) {
            return .{};
        }
        self.next_note_generation +%= 1;
        const id = self.next_script_id;
        if (id == 0) {
            return .{};
        }
        self.next_script_id +%= 1;
        const url_copy = self.allocator.dupe(u8, url) catch {
            return .{};
        };
        const source_copy = self.allocator.dupe(u8, source) catch {
            self.allocator.free(url_copy);
            return .{};
        };
        const map_copy = self.allocator.dupe(u8, map_text) catch {
            self.allocator.free(url_copy);
            self.allocator.free(source_copy);
            return .{};
        };
        var stored = Script{ .id = id, .url = url_copy, .source = source_copy, .end_line = ends.line, .end_column = ends.column, .hash = undefined, .source_map_url = map_copy, .last_note_generation = note_generation };
        formatHash(source, &stored.hash);
        self.scripts.append(self.allocator, stored) catch {
            freeScript(self.allocator, stored);
            return .{};
        };
        self.active_script_id = id;
        self.script_bytes += scriptStorageBytes(stored);
        while (self.scripts.items.len > 1 and (self.scripts.items.len > max_retained_scripts or self.script_bytes > max_retained_source_bytes)) {
            const evicted = self.scripts.orderedRemove(0);
            self.script_bytes -= scriptStorageBytes(evicted);
            freeScript(self.allocator, evicted);
        }
        return .{ .id = id, .published = cloneScriptInfo(self.allocator, self.scripts.items[self.scripts.items.len - 1]) catch null };
    }

    pub fn idForUrlLocked(self: *Journal, url: []const u8) u32 {
        var index = self.scripts.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.scripts.items[index].url, url)) return self.scripts.items[index].id;
        }
        return 0;
    }

    pub fn snapshotLocked(self: *Journal) []ScriptInfo {
        if (self.scripts.items.len == 0) return &.{};
        const out = self.allocator.alloc(ScriptInfo, self.scripts.items.len) catch return &.{};
        for (self.scripts.items, 0..) |script, i| {
            out[i] = cloneScriptInfo(self.allocator, script) catch {
                for (out[0..i]) |info| freeScriptInfoWithAllocator(self.allocator, info);
                self.allocator.free(out);
                return &.{};
            };
        }
        return out;
    }

    pub fn snapshotByIdLocked(self: *Journal, id: u32) ?ScriptInfo {
        for (self.scripts.items) |script| {
            if (script.id != id) continue;
            return cloneScriptInfo(self.allocator, script) catch null;
        }
        return null;
    }

    pub fn findByIdLocked(self: *Journal, id: u32) ?*Script {
        if (id == 0) return null;
        for (self.scripts.items) |*script| {
            if (script.id == id) return script;
        }
        return null;
    }

    pub fn findByTagLocked(self: *Journal, tag: u64) ?*Script {
        if (tag == 0 or tag > std.math.maxInt(u32)) return null;
        return self.findByIdLocked(@intCast(tag));
    }

    pub fn recordLocationLocked(self: *Journal, script_tag: u64, line: i32, column: i32) void {
        const script = self.findByTagLocked(script_tag) orelse return;
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
        script.break_locations.append(self.allocator, .{ .line = line, .column = column0 }) catch {
            script.break_locations_truncated = true;
        };
    }

    pub fn completeLocationsLocked(self: *Journal, tag: u64, truncated: bool) ?u32 {
        const script = self.findByTagLocked(tag) orelse return null;
        script.break_locations_collected = true;
        script.break_locations_truncated = truncated;
        return script.id;
    }

    pub fn deinit(self: *Journal) void {
        for (self.scripts.items) |script| freeScript(self.allocator, script);
        self.scripts.deinit(self.allocator);
    }
};

pub fn freeScriptInfo(allocator: std.mem.Allocator, info: ScriptInfo) void {
    freeScriptInfoWithAllocator(allocator, info);
}

pub fn freeScriptSnapshot(allocator: std.mem.Allocator, scripts: []ScriptInfo) void {
    for (scripts) |script| freeScriptInfo(allocator, script);
    if (scripts.len != 0) allocator.free(scripts);
}

fn scriptStorageBytes(script: Script) usize {
    return script.url.len + script.source.len + script.hash.len + script.source_map_url.len;
}

fn freeScript(allocator: std.mem.Allocator, script: Script) void {
    allocator.free(script.url);
    allocator.free(script.source);
    allocator.free(script.source_map_url);
    var owned = script;
    owned.break_locations.deinit(allocator);
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

test "source journal: registration and snapshots release partial OOM allocations" {
    for (0..18) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var journal = Journal{ .allocator = allocator };
        defer journal.deinit();
        const registered = journal.registerLocked(prepare("test.js", "let answer = 42;\n//# sourceMappingURL=test.map"));
        if (registered.published) |info| {
            defer freeScriptInfo(allocator, info);
            try std.testing.expectEqual(registered.id, info.id);
        }
        const snapshot = journal.snapshotLocked();
        defer freeScriptSnapshot(allocator, snapshot);
        if (registered.id != 0) {
            try std.testing.expect(journal.findByTagLocked(registered.id) != null);
        }
    }
}

test "source journal: tags never guess and location completion retains its protocol" {
    const allocator = std.testing.allocator;
    var journal = Journal{ .allocator = allocator };
    defer journal.deinit();
    const registered = journal.registerLocked(prepare("same.js", "first"));
    if (registered.published) |info| freeScriptInfo(allocator, info);
    try std.testing.expect(registered.id != 0);
    try std.testing.expect(journal.findByTagLocked(0) == null);
    try std.testing.expect(journal.findByTagLocked(@as(u64, std.math.maxInt(u32)) + 1) == null);
    try std.testing.expect(journal.findByTagLocked(registered.id + 1) == null);
    journal.recordLocationLocked(registered.id, 2, 3);
    journal.recordLocationLocked(registered.id, 2, 3);
    const script = journal.findByTagLocked(registered.id).?;
    try std.testing.expectEqual(@as(usize, 1), script.break_locations.items.len);
    try std.testing.expectEqual(@as(i32, 2), script.break_locations.items[0].column);
    try std.testing.expectEqual(@as(?u32, registered.id), journal.completeLocationsLocked(registered.id, false));
    journal.recordLocationLocked(registered.id, 4, 0);
    try std.testing.expect(!script.break_locations_collected);
    try std.testing.expectEqual(@as(usize, 1), script.break_locations.items.len);
    try std.testing.expectEqual(@as(i32, 4), script.break_locations.items[0].line);
    _ = journal.completeLocationsLocked(registered.id, true);
    journal.recordLocationLocked(registered.id, 5, 1);
    try std.testing.expect(script.break_locations_truncated);
    try std.testing.expectEqual(@as(usize, 1), script.break_locations.items.len);
}

test "source journal: exhausted counters do not register or publish" {
    var journal = Journal{ .allocator = std.testing.allocator, .next_script_id = 0 };
    defer journal.deinit();
    const no_id = journal.registerLocked(prepare("test.js", "source"));
    try std.testing.expectEqual(@as(u32, 0), no_id.id);
    try std.testing.expect(no_id.published == null);
    // Generation advances before the script-id exhaustion check.
    try std.testing.expectEqual(@as(u64, 2), journal.next_note_generation);
    journal.next_script_id = 1;
    journal.next_note_generation = 0;
    const no_generation = journal.registerLocked(prepare("test.js", "source"));
    try std.testing.expectEqual(@as(u32, 0), no_generation.id);
    try std.testing.expectEqual(@as(u32, 1), journal.next_script_id);
    try std.testing.expectEqual(@as(usize, 0), journal.scripts.items.len);
}
