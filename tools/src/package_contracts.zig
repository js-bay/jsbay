//! Repository-level package-boundary contracts. Package unit tests cover their behavior; these tests prevent the root engine from leaking back into them.
const std = @import("std");
const sdk = @import("sdk.zig");

const testing = std.testing;
const Dir = std.Io.Dir;

fn root(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.process.currentPathAlloc(io, allocator);
}

fn makeTemp(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    var random: [12]u8 = undefined;
    io.random(&random);
    const directory = try std.fmt.allocPrint(allocator, "/tmp/{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
    try Dir.cwd().createDir(io, directory, .default_dir);
    return directory;
}

fn path(allocator: std.mem.Allocator, base: []const u8, parts: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(allocator);
    try all.append(allocator, base);
    try all.appendSlice(allocator, parts);
    return std.fs.path.join(allocator, all.items);
}

fn read(allocator: std.mem.Allocator, io: std.Io, base: []const u8, parts: []const []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, try path(allocator, base, parts), allocator, .limited(16 * 1024 * 1024));
}

fn exists(io: std.Io, allocator: std.mem.Allocator, base: []const u8, parts: []const []const u8) !bool {
    Dir.cwd().access(io, try path(allocator, base, parts), .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn sources(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, directory: []const u8) ![]u8 {
    var output = try sdk.run(allocator, io, &.{ "rg", "--files", directory, "-g", "*.zig" }, cwd);
    defer output.deinit();
    try testing.expect(output.succeeded());
    return allocator.dupe(u8, output.result.stdout);
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, text, needle) != null);
}

fn expectNotContains(text: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, text, needle) == null);
}

fn testTitlesAreNotTransport(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, root_path: []const u8) !void {
    const listing = try sources(allocator, io, cwd, try path(allocator, root_path, &.{ "src", "tests" }));
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;
        const text = try Dir.cwd().readFileAlloc(io, name, allocator, .limited(16 * 1024 * 1024));
        var rest = text;
        while (std.mem.indexOf(u8, rest, "test \"")) |start| {
            rest = rest[start + "test \"".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            try testing.expect(!std.mem.startsWith(u8, rest[0..end], "transport:"));
            rest = rest[end + 1 ..];
        }
    }
}

test "Inspector packages keep generic and transport code outside the engine suite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const cwd = try root(allocator, io);
    const inspector = try path(allocator, cwd, &.{ "libs", "inspector" });

    const listing = try sources(allocator, io, cwd, try path(allocator, inspector, &.{"src"}));
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;
        const text = try Dir.cwd().readFileAlloc(io, name, allocator, .limited(16 * 1024 * 1024));
        if (std.mem.indexOf(u8, text, "pub fn Module(comptime Host: type) type") != null) try expectNotContains(text, "test \"");
        try expectNotContains(text, "@import(\"inspector_transport\")");
        try expectNotContains(text, "std.posix.socket");
        try expectNotContains(text, "std.c.send(");
    }
    try testTitlesAreNotTransport(allocator, io, cwd, cwd);
    try testing.expect(try exists(io, allocator, cwd, &.{ "libs", "inspector", "src", "protocol_tests.zig" }));
    try testing.expect(!try exists(io, allocator, cwd, &.{ "src", "tests", "inspector_protocol_tests.zig" }));

    for ([_][]const u8{ "inspector", "inspector_transport" }) |name| {
        for ([_][]const u8{ "build.zig", "build.zig.zon", "LICENSE", "readme.md", "src/root.zig" }) |required| {
            try testing.expect(try exists(io, allocator, cwd, &.{ "libs", name, required }));
        }
        const build = try read(allocator, io, cwd, &.{ "libs", name, "build.zig" });
        try expectContains(build, "b.step(\"test\"");
    }
    const manifest = try read(allocator, io, cwd, &.{ "libs", "inspector", "build.zig.zon" });
    try expectNotContains(manifest, "inspector_transport");
}

test "js_event_loop owns native helpers without importing the engine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const cwd = try root(allocator, io);
    const package = try path(allocator, cwd, &.{ "libs", "js_event_loop" });
    const listing = try sources(allocator, io, cwd, try path(allocator, package, &.{"src"}));
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;
        const source = try Dir.cwd().readFileAlloc(io, name, allocator, .limited(16 * 1024 * 1024));
        var remaining = source;
        while (std.mem.indexOf(u8, remaining, "@import(\"")) |start| {
            remaining = remaining[start + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, remaining, '"') orelse break;
            const imported = remaining[0..end];
            if (!std.mem.eql(u8, imported, "std") and !std.mem.eql(u8, imported, "builtin") and !std.mem.eql(u8, imported, "zev") and !std.mem.eql(u8, imported, "js_event_loop")) {
                if (std.mem.indexOfScalar(u8, imported, '/') != null or std.mem.endsWith(u8, imported, ".zig")) {
                    const local = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(name) orelse return error.InvalidPath, imported });
                    try testing.expect(std.mem.startsWith(u8, local, package));
                }
            }
            remaining = remaining[end + 1 ..];
        }
    }
}

test "zev stays a self-contained native event-loop package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const cwd = try root(allocator, io);
    const package = try path(allocator, cwd, &.{ "libs", "zev" });
    const manifest = try read(allocator, io, cwd, &.{ "libs", "zev", "build.zig.zon" });
    try expectContains(manifest, "\"readme.md\"");
    const build = try read(allocator, io, cwd, &.{ "libs", "zev", "build.zig" });
    const support = try read(allocator, io, cwd, &.{ "libs", "zev", "build_support.zig" });
    const native = try read(allocator, io, cwd, &.{ "libs", "zev", "src", "native.zig" });
    const root_source = try read(allocator, io, cwd, &.{ "libs", "zev", "src", "root.zig" });
    try expectContains(native, "const uses_futex = builtin.os.tag == .linux;");
    try expectContains(native, "const PthreadState = struct");
    try expectContains(native, "@import(\"ohos_pthread\")");
    try expectContains(native, "pthread_mutex_t");
    try expectNotContains(native, "extern fn jsbay_");
    try expectContains(build, "if (ohos)");
    try expectContains(support, "addTranslateC");
    try expectContains(support, "configureOhosMutex");
    try expectContains(root_source, "pub const Loop");
    try expectContains(root_source, "pub const Timer");
    try expectNotContains(root_source, "pub const TimerQueue");
    try testing.expect(!try exists(io, allocator, cwd, &.{ "libs", "zev", "src", "timer_queue.zig" }));
    try testing.expect(!try exists(io, allocator, cwd, &.{ "libs", "zev", "src", "ohos_mutex.c" }));

    var c_sources = try sdk.run(allocator, io, &.{ "rg", "--files", try path(allocator, package, &.{"src"}), "-g", "*.c" }, cwd);
    defer c_sources.deinit();
    try testing.expect(c_sources.succeeded());
    const expected_c = try std.fmt.allocPrint(allocator, "{s}\n", .{try path(allocator, package, &.{ "src", "ohos_stress_statx.c" })});
    try testing.expectEqualStrings(expected_c, c_sources.result.stdout);
    const header = try read(allocator, io, cwd, &.{ "libs", "zev", "src", "ohos_pthread.h" });
    const stress_compat = try read(allocator, io, cwd, &.{ "libs", "zev", "src", "ohos_stress_statx.c" });
    try expectContains(header, "#include <pthread.h>");
    try expectContains(header, "PTHREAD_MUTEX_INITIALIZER");
    try expectContains(stress_compat, "statx");
    try expectNotContains(stress_compat, "pthread");
    try testing.expect(!try exists(io, allocator, cwd, &.{ "libs", "zev", "src", "event_loop.c" }));
    try testing.expect(!try exists(io, allocator, cwd, &.{ "libs", "zev", "src", "event_loop.h" }));
    try testing.expect(!try exists(io, allocator, cwd, &.{ "src", "event_loop.c" }));
    try testing.expect(!try exists(io, allocator, cwd, &.{ "src", "event_loop.h" }));

    const loop = try read(allocator, io, cwd, &.{ "libs", "zev", "src", "loop.zig" });
    for ([_][]const u8{ "Task", "RunOnceHooks", "RunOnceResult", "postTask", "takeTasks", "takeTaskForOwner", "releaseAllTasks", "closeTasks", "task_mutex", "tasks_closed", "std.ArrayList(Task)" }) |needle| try expectNotContains(loop, needle);

    const zig_sources = try sources(allocator, io, cwd, try path(allocator, package, &.{"src"}));
    var source_lines = std.mem.splitScalar(u8, zig_sources, '\n');
    while (source_lines.next()) |name| {
        if (name.len == 0) continue;
        const text = try Dir.cwd().readFileAlloc(io, name, allocator, .limited(16 * 1024 * 1024));
        for ([_][]const u8{ "std.Io.Mutex", "std.Io.Condition", "std.Io.Clock", "@import(\"build_options\")" }) |forbidden| try expectNotContains(text, forbidden);
    }

    var package_files = try sdk.run(allocator, io, &.{ "rg", "--files", package }, cwd);
    defer package_files.deinit();
    try testing.expect(package_files.succeeded());
    var files = std.mem.splitScalar(u8, package_files.result.stdout, '\n');
    while (files.next()) |name| {
        if (name.len == 0) continue;
        const text = Dir.cwd().readFileAlloc(io, name, allocator, .limited(16 * 1024 * 1024)) catch continue;
        const lowered = try std.ascii.allocLowerString(allocator, text);
        for ([_][]const u8{ "jsbay", "js-bay", "jsbay" }) |engine_name| try expectNotContains(lowered, engine_name);
    }
}

test "root accepts an OpenHarmony sysroot without a device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const cwd = try root(allocator, io);
    const sysroot = try makeTemp(allocator, io, "jsbay-ohos-sysroot");
    defer Dir.cwd().deleteTree(io, sysroot) catch {};
    var output = try sdk.run(allocator, io, &.{ "zig", "build", "--help", "-Dtarget=aarch64-linux-ohos", try std.fmt.allocPrint(allocator, "-Dohos-sysroot={s}", .{sysroot}) }, cwd);
    defer output.deinit();
    try testing.expect(output.succeeded());
}

fn copyTree(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, source: []const u8, destination: []const u8) !void {
    var output = try sdk.run(allocator, io, &.{ "cp", "-R", source, destination }, cwd);
    defer output.deinit();
    if (!output.succeeded()) return error.CopyFailed;
}

fn fingerprint(allocator: std.mem.Allocator, io: std.Io, fixture: []const u8, shadow: []const u8, wrapper: []const u8, contents: []const u8) ![]u8 {
    try writeFile(io, wrapper, contents);
    // Drop local caches so @embedFile inputs under vendor/ (e.g. quickjs-opcode.h) are rehashed.
    Dir.cwd().deleteTree(io, try path(allocator, shadow, &.{".zig-cache"})) catch {};
    Dir.cwd().deleteTree(io, try path(allocator, fixture, &.{".zig-cache"})) catch {};
    const installed = try path(allocator, shadow, &.{"installed"});
    var output = try sdk.run(allocator, io, &.{ "zig", "build", "--prefix", installed }, fixture);
    defer output.deinit();
    if (!output.succeeded()) {
        std.debug.print("cache identity build failed:\n{s}\n{s}", .{ output.result.stdout, output.result.stderr });
        return error.BuildFailed;
    }
    const options = try Dir.cwd().readFileAlloc(io, try path(allocator, installed, &.{"options.zig"}), allocator, .limited(1024 * 1024));
    const marker = std.mem.indexOf(u8, options, "bytecode_fingerprint") orelse return error.MissingFingerprint;
    const first_quote = marker + (std.mem.indexOfScalar(u8, options[marker..], '"') orelse return error.MissingFingerprint) + 1;
    const end_quote = first_quote + (std.mem.indexOfScalar(u8, options[first_quote..], '"') orelse return error.MissingFingerprint);
    const value = options[first_quote..end_quote];
    if (value.len != 64) return error.InvalidFingerprint;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidFingerprint;
    return allocator.dupe(u8, value);
}

fn writeFile(io: std.Io, target: []const u8, contents: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = target, .data = contents });
}

test "cache fingerprint changes for the wrapper and pinned QuickJS-NG input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = testing.io;
    const cwd = try root(allocator, io);
    const temp = try makeTemp(allocator, io, "jsbay-cache-identity");
    defer Dir.cwd().deleteTree(io, temp) catch {};
    const shadow = try path(allocator, temp, &.{"core"});
    try Dir.cwd().createDir(io, shadow, .default_dir);

    var root_dir = try Dir.cwd().openDir(io, cwd, .{ .iterate = true });
    defer root_dir.close(io);
    var iterator = root_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-out") or std.mem.eql(u8, entry.name, "src") or std.mem.eql(u8, entry.name, "tests") or std.mem.eql(u8, entry.name, "vendor")) continue;
        try Dir.cwd().symLink(io, try path(allocator, cwd, &.{entry.name}), try path(allocator, shadow, &.{entry.name}), .{});
    }
    try Dir.cwd().createDir(io, try path(allocator, shadow, &.{"vendor"}), .default_dir);
    try copyTree(allocator, io, cwd, try path(allocator, cwd, &.{ "vendor", "quickjs-ng" }), try path(allocator, shadow, &.{ "vendor", "quickjs-ng" }));
    var vendor = try Dir.cwd().openDir(io, try path(allocator, cwd, &.{"vendor"}), .{ .iterate = true });
    defer vendor.close(io);
    var vendor_iterator = vendor.iterate();
    while (try vendor_iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "quickjs-ng")) continue;
        try Dir.cwd().symLink(io, try path(allocator, cwd, &.{ "vendor", entry.name }), try path(allocator, shadow, &.{ "vendor", entry.name }), .{});
    }
    try copyTree(allocator, io, cwd, try path(allocator, cwd, &.{"src"}), try path(allocator, shadow, &.{"src"}));
    const fixture = try path(allocator, shadow, &.{ "tests", "cache-identity" });
    try Dir.cwd().createDirPath(io, try path(allocator, shadow, &.{"tests"}));
    try copyTree(allocator, io, cwd, try path(allocator, cwd, &.{ "tests", "cache-identity" }), fixture);

    const source_path = try path(allocator, cwd, &.{ "src", "script", "cjs_wrapper.zig" });
    const wrapper = try path(allocator, shadow, &.{ "src", "script", "cjs_wrapper.zig" });
    const source = try Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(1024 * 1024));
    const source_before = try allocator.dupe(u8, source);
    try testing.expect(std.mem.startsWith(u8, wrapper, shadow));
    const original = try fingerprint(allocator, io, fixture, shadow, wrapper, source);
    const pivot = std.mem.indexOf(u8, source, "(function (") orelse return error.WrapperShapeChanged;
    const changed = try std.fmt.allocPrint(allocator, "{s}(function /* changed wrapper */ ({s}", .{ source[0..pivot], source[pivot + "(function (".len ..] });
    const changed_fingerprint = try fingerprint(allocator, io, fixture, shadow, wrapper, changed);
    try testing.expect(!std.mem.eql(u8, original, changed_fingerprint));
    try testing.expectEqualStrings(source_before, try Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(1024 * 1024)));
    try testing.expectEqualStrings(original, try fingerprint(allocator, io, fixture, shadow, wrapper, source));

    const opcode = try path(allocator, shadow, &.{ "vendor", "quickjs-ng", "quickjs-opcode.h" });
    const opcode_before = try Dir.cwd().readFileAlloc(io, opcode, allocator, .limited(8 * 1024 * 1024));
    try writeFile(io, opcode, try std.fmt.allocPrint(allocator, "{s}\n/* cache identity fixture */\n", .{opcode_before}));
    try testing.expect(!std.mem.eql(u8, original, try fingerprint(allocator, io, fixture, shadow, wrapper, source)));
    try writeFile(io, opcode, opcode_before);
    try testing.expectEqualStrings(original, try fingerprint(allocator, io, fixture, shadow, wrapper, source));
    try testing.expectEqualStrings(source_before, try Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(1024 * 1024)));
}
