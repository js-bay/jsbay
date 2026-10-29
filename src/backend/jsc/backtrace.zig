//! Structured frames from `JSContextCreateBacktrace`.
//!
//! The JavaScriptCore framework exports this function without declaring it in the SDK's public header. Lines look like `functionName@url:line:column`.

const std = @import("std");
const engine = @import("../../engine.zig");
const common = @import("common.zig");

const jsc = common.jsc;

extern "c" fn JSContextCreateBacktrace(ctx: jsc.JSContextRef, maxStackSize: c_uint) jsc.JSStringRef;

pub const Frame = struct {
    name: []u8,
    url: []u8,
    line: i32,
    column: i32,
};

pub fn parse(text: []const u8) []Frame {
    return parseLines(text);
}

pub fn freeFrames(frames: []Frame) void {
    for (frames) |frame| {
        if (frame.name.len != 0) std.heap.c_allocator.free(frame.name);
        if (frame.url.len != 0) std.heap.c_allocator.free(frame.url);
    }
    if (frames.len != 0) std.heap.c_allocator.free(frames);
}

pub fn copyStack(instance_id: i32) []Frame {
    const ctx = engine.getContext(instance_id) orelse return &.{};
    const text_ref = JSContextCreateBacktrace(@ptrCast(ctx), 32);
    if (text_ref == null) return &.{};
    defer jsc.JSStringRelease(text_ref);
    const text = common.jsStringToOwned(text_ref) orelse return &.{};
    defer std.heap.c_allocator.free(text);
    return parseLines(text);
}

fn parseLines(text: []const u8) []Frame {
    var list: std.ArrayList(Frame) = .empty;
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..nl], " \r");
        rest = if (nl == rest.len) rest[rest.len..] else rest[nl + 1 ..];
        if (line.len == 0) continue;
        const frame = parseLine(line) orelse continue;
        list.append(std.heap.c_allocator, frame) catch {
            if (frame.name.len != 0) std.heap.c_allocator.free(frame.name);
            if (frame.url.len != 0) std.heap.c_allocator.free(frame.url);
            break;
        };
    }
    return list.toOwnedSlice(std.heap.c_allocator) catch &.{};
}

fn parseLine(line: []const u8) ?Frame {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '#') return parseNumbered(trimmed);
    const at = std.mem.indexOfScalar(u8, trimmed, '@') orelse return null;
    const name = trimmed[0..at];
    var source = trimmed[at + 1 ..];
    if (std.mem.eql(u8, source, "[native code]")) return null;
    var column: i32 = 0;
    var line_no: i32 = 1;
    if (std.mem.lastIndexOfScalar(u8, source, ':')) |colon| {
        column = std.fmt.parseInt(i32, source[colon + 1 ..], 10) catch 0;
        source = source[0..colon];
        if (std.mem.lastIndexOfScalar(u8, source, ':')) |line_colon| {
            line_no = std.fmt.parseInt(i32, source[line_colon + 1 ..], 10) catch 1;
            source = source[0..line_colon];
        }
    }
    if (column > 0) column -= 1;
    return .{
        .name = std.heap.c_allocator.dupe(u8, name) catch &.{},
        .url = std.heap.c_allocator.dupe(u8, source) catch &.{},
        .line = if (line_no > 0) line_no else 1,
        .column = column,
    };
}

fn parseNumbered(line: []const u8) ?Frame {
    var i: usize = 1;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i < line.len and line[i] == ' ') i += 1;
    const marker = " at ";
    const at = std.mem.indexOf(u8, line[i..], marker) orelse return null;
    var name = std.mem.trim(u8, line[i..][0..at], " ");
    if (std.mem.endsWith(u8, name, "()")) name = name[0 .. name.len - 2];
    const source = line[i + at + marker.len ..];
    if (std.mem.eql(u8, source, "[native code]") or name.len == 0) return null;
    const joined = std.fmt.allocPrint(std.heap.c_allocator, "{s}@{s}", .{ name, source }) catch return null;
    defer std.heap.c_allocator.free(joined);
    return parseLine(joined);
}

/// Copies backtrace frames into caller storage. Does not call the Zig allocator. `JSContextCreateBacktrace` still builds one temporary JSC string; its UTF-8 is copied into `out` and the string is released before return. `out` items expose `name`, `url`, `name_len`, `url_len`, `line`, and `column` (line 1-based, column 0-based).
pub fn writeStack(instance_id: i32, out: anytype) usize {
    if (out.len == 0) return 0;
    const ctx = engine.getContext(instance_id) orelse return 0;
    const max_frames: c_uint = @intCast(@min(out.len, 32));
    const text_ref = JSContextCreateBacktrace(@ptrCast(ctx), max_frames);
    if (text_ref == null) return 0;
    defer jsc.JSStringRelease(text_ref);
    var text_buf: [4096]u8 = undefined;
    const written = jsc.JSStringGetUTF8CString(text_ref, &text_buf, text_buf.len);
    if (written < 2) return 0;
    return parseInto(text_buf[0 .. written - 1], out);
}

fn parseInto(text: []const u8, out: anytype) usize {
    var rest = text;
    var count: usize = 0;
    while (rest.len > 0 and count < out.len) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..nl], " \r");
        rest = if (nl == rest.len) rest[rest.len..] else rest[nl + 1 ..];
        if (line.len == 0) continue;
        if (!fillFrame(&out[count], line)) continue;
        count += 1;
    }
    return count;
}

fn fillFrame(frame: anytype, line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '#') return fillNumbered(frame, trimmed);
    return fillAt(frame, trimmed);
}

fn fillAt(frame: anytype, trimmed: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, trimmed, '@') orelse return false;
    return fillLocation(frame, trimmed[0..at], trimmed[at + 1 ..]);
}

fn fillNumbered(frame: anytype, line: []const u8) bool {
    var i: usize = 1;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i < line.len and line[i] == ' ') i += 1;
    const marker = " at ";
    const at = std.mem.indexOf(u8, line[i..], marker) orelse return false;
    var name = std.mem.trim(u8, line[i..][0..at], " ");
    if (std.mem.endsWith(u8, name, "()")) name = name[0 .. name.len - 2];
    if (name.len == 0) return false;
    return fillLocation(frame, name, line[i + at + marker.len ..]);
}

fn fillLocation(frame: anytype, name: []const u8, source_in: []const u8) bool {
    var source = source_in;
    if (std.mem.eql(u8, source, "[native code]")) return false;
    var column: i32 = 0;
    var line_no: i32 = 1;
    if (std.mem.lastIndexOfScalar(u8, source, ':')) |colon| {
        column = std.fmt.parseInt(i32, source[colon + 1 ..], 10) catch 0;
        source = source[0..colon];
        if (std.mem.lastIndexOfScalar(u8, source, ':')) |line_colon| {
            line_no = std.fmt.parseInt(i32, source[line_colon + 1 ..], 10) catch 1;
            source = source[0..line_colon];
        }
    }
    if (column > 0) column -= 1;
    const name_len = @min(name.len, frame.name.len);
    const url_len = @min(source.len, frame.url.len);
    if (name_len != 0) @memcpy(frame.name[0..name_len], name[0..name_len]);
    if (url_len != 0) @memcpy(frame.url[0..url_len], source[0..url_len]);
    frame.name_len = name_len;
    frame.url_len = url_len;
    frame.line = if (line_no > 0) line_no else 1;
    frame.column = column;
    return true;
}
