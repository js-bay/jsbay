const std = @import("std");
const builtin = @import("builtin");
const repository = @import("repository.zig");
const ios_stdlib = @import("ios_stdlib.zig");
const apple_archive = @import("apple_archive.zig");
pub const test_tool_path = if (@import("builtin").is_test) @import("tool_options").executable else "";

const Exit = error{ Usage, InvalidInput, PolicyFailure, ExternalFailure };

test {
    _ = @import("contracts.zig");
    _ = @import("package_contracts.zig");
    _ = @import("apple_archive.zig");
    _ = @import("apple_archive_tests.zig");
    _ = @import("ios_stdlib_tests.zig");
    _ = @import("ios_stdlib.zig");
    _ = @import("r8_tests.zig");
    _ = @import("distribution_tests.zig");
}

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) return usage();
    if (repository.handles(argv[1])) return repository.run(init, argv[1..]);
    if (std.mem.eql(u8, argv[1], "prepare-ios-stdlib")) return ios_stdlib.run(init, argv[2..]);
    if (std.mem.eql(u8, argv[1], "check-diagnostic-exports")) return checkDiagnosticExports(init, argv[2..]);
    if (std.mem.eql(u8, argv[1], "apple-archive")) {
        apple_archive.run(init, argv[2..]) catch |err| {
            std.process.exit(if (err == error.PolicyFailure) 1 else 2);
        };
        return;
    }
    const code = dispatch(argv[1], argv[2..]) catch |err| switch (err) {
        error.Usage => 2,
        error.PolicyFailure => 1,
        error.ExternalFailure => 1,
        else => return err,
    };
    std.process.exit(code);
}

fn usage() !void {
    std.debug.print("usage: jsbay-tool <apple-archive|check-c-abi|write-android-exports-map|check-r8|prepare-ios-stdlib> ...\n", .{});
    return error.Usage;
}

fn dispatch(command: []const u8, args: []const []const u8) !u8 {
    if (std.mem.eql(u8, command, "check-r8")) return checkR8(args);
    if (std.mem.eql(u8, command, "check-c-abi")) return checkCAbi(args);
    if (std.mem.eql(u8, command, "write-android-exports-map")) return writeAndroidExportsMap(args);
    _ = usage() catch {};
    return error.Usage;
}

fn checkR8(args: []const []const u8) !u8 {
    if (args.len != 2) return error.Usage;
    const mapping_path = args[0];
    const jar_path = args[1];
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const mapping = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), mapping_path, std.heap.page_allocator, .limited(16 * 1024 * 1024));
    defer std.heap.page_allocator.free(mapping);
    const jar = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), jar_path, std.heap.page_allocator, .limited(128 * 1024 * 1024));
    defer std.heap.page_allocator.free(jar);
    if (!zipHas(jar, "io/jsbay/consumer/ConsumerMain.class")) {
        std.debug.print("missing input class: io.jsbay.consumer.ConsumerMain\n", .{});
        return error.PolicyFailure;
    }
    if (!zipHas(jar, "io/jsbay/consumer/JavaConsumer.class")) {
        std.debug.print("missing input class: io.jsbay.consumer.JavaConsumer\n", .{});
        return error.PolicyFailure;
    }
    return validateMapping(mapping);
}

fn validateMapping(mapping: []const u8) !u8 {
    const main_target = mappingTarget(mapping, "io.jsbay.consumer.ConsumerMain");
    const consumer = mappingTarget(mapping, "io.jsbay.consumer.JavaConsumer");
    if (main_target == null or !std.mem.eql(u8, main_target.?, "io.jsbay.consumer.ConsumerMain")) {
        std.debug.print("R8 did not preserve the consumer entrypoint\n", .{});
        return error.PolicyFailure;
    }
    if (consumer != null and std.mem.eql(u8, consumer.?, "io.jsbay.consumer.JavaConsumer")) {
        std.debug.print("R8 left the external Java consumer class unchanged\n", .{});
        return error.PolicyFailure;
    }
    return 0;
}

fn mappingTarget(mapping: []const u8, source: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, mapping, '\n');
    var target: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, source)) continue;
        if (line.len <= source.len or !std.mem.startsWith(u8, line[source.len..], " -> ") or !std.mem.endsWith(u8, line, ":")) continue;
        const value = line[source.len + 4 .. line.len - 1];
        if (std.mem.indexOfAny(u8, value, " \t\r") == null and value.len != 0) target = value;
    }
    return target;
}

fn zipHas(bytes: []const u8, name: []const u8) bool {
    // Only records named by the end-of-central-directory record count. A fake signature inside compressed file data must never satisfy a class check.
    if (bytes.len < 22) return false;
    var end_record = bytes.len - 22;
    while (true) {
        if (std.mem.eql(u8, bytes[end_record .. end_record + 4], "PK\x05\x06") and end_record + 22 + (readLe16(bytes[end_record + 20 .. end_record + 22]) orelse return false) == bytes.len) break;
        if (end_record == 0 or bytes.len - end_record > 65557) return false;
        end_record -= 1;
    }
    if (readLe16(bytes[end_record + 4 .. end_record + 6]).? != 0 or readLe16(bytes[end_record + 6 .. end_record + 8]).? != 0) return false;
    const entries = readLe16(bytes[end_record + 10 .. end_record + 12]).?;
    if (entries != readLe16(bytes[end_record + 8 .. end_record + 10]).?) return false;
    const size = std.mem.readInt(u32, bytes[end_record + 12 ..][0..4], .little);
    var i: usize = std.mem.readInt(u32, bytes[end_record + 16 ..][0..4], .little);
    if (i > end_record or size != end_record - i) return false;
    var found = false;
    for (0..entries) |_| {
        if (i > end_record or end_record - i < 46 or !std.mem.eql(u8, bytes[i .. i + 4], "PK\x01\x02")) return false;
        const name_len = readLe16(bytes[i + 28 .. i + 30]) orelse return false;
        const extra_len = readLe16(bytes[i + 30 .. i + 32]) orelse return false;
        const comment_len = readLe16(bytes[i + 32 .. i + 34]) orelse return false;
        const end = i + 46 + name_len + extra_len + comment_len;
        if (end > end_record) return false;
        if (std.mem.eql(u8, bytes[i + 46 .. i + 46 + name_len], name)) found = true;
        i = end;
    }
    return i == end_record and found;
}

fn readLe16(slice: []const u8) ?usize {
    if (slice.len != 2) return null;
    return @as(usize, slice[0]) | (@as(usize, slice[1]) << 8);
}

fn checkCAbi(args: []const []const u8) !u8 {
    var nm: []const u8 = "nm";
    var library: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--nm")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            nm = args[index];
        } else if (library == null) {
            library = arg;
        } else return error.Usage;
    }
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    // Prefer the system compilers. Android NDK setup often puts a target-clang
    // named `cc` ahead on PATH, which breaks these host syntax-only probes.
    const cc: []const u8 = if (builtin.os.tag == .windows) "cc" else "/usr/bin/cc";
    const cxx: []const u8 = if (builtin.os.tag == .windows) "c++" else "/usr/bin/c++";
    const consumers = [_][]const u8{ "tests/c_consumer.c", "tests/bytecode_consumer.c", "tests/native_sync_consumer.c", "tests/host_wake_consumer.c" };
    for (consumers) |consumer| {
        try requireExternal(std.heap.page_allocator, threaded.io(), &.{ cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsyntax-only", "-I", "include", consumer });
        try requireExternal(std.heap.page_allocator, threaded.io(), &.{ cxx, "-x", "c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-fsyntax-only", "-I", "include", consumer });
    }
    const lib = library orelse return 0;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var expected = try headerSymbols(allocator);
    defer expected.deinit();
    const output = try runOutput(allocator, threaded.io(), &.{ nm, "-g", lib });
    var actual = std.StringHashMap(void).init(allocator);
    defer actual.deinit();
    var forbidden = std.ArrayList([]const u8).empty;
    defer forbidden.deinit(allocator);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const address = it.next() orelse continue;
        const kind = it.next() orelse continue;
        const symbol_raw = it.next() orelse continue;
        if (!isHex(address) or kind.len != 1 or (kind[0] >= 'a' and kind[0] <= 'z' and kind[0] == 'u') or kind[0] == 'U') continue;
        const symbol = if (std.mem.startsWith(u8, symbol_raw, "_")) symbol_raw[1..] else symbol_raw;
        // QuickJS C shims (jsbay_qjs_*) are engine-private wrappers for Zig; not public ABI.
        if (std.mem.startsWith(u8, symbol, "jsbay_") and !std.mem.startsWith(u8, symbol, "jsbay_qjs_")) try actual.put(symbol, {});
        if (std.mem.startsWith(u8, symbol, "no" ++ "ok_engine_") or std.mem.startsWith(u8, symbol, "z" ++ "je_") or std.mem.startsWith(u8, symbol, "z" ++ "jse_") or std.mem.startsWith(u8, symbol, "Java_") or std.mem.eql(u8, symbol, "JNI_OnLoad")) try forbidden.append(allocator, symbol);
    }
    var failed = false;
    var expected_it = expected.keyIterator();
    while (expected_it.next()) |symbol| if (!actual.contains(symbol.*)) {
        failed = true;
        std.debug.print("missing public symbol: {s}\n", .{symbol.*});
    };
    var actual_it = actual.keyIterator();
    while (actual_it.next()) |symbol| if (!expected.contains(symbol.*)) {
        failed = true;
        std.debug.print("undeclared public symbol: {s}\n", .{symbol.*});
    };
    for (forbidden.items) |symbol| {
        failed = true;
        std.debug.print("unexpected C ABI symbol: {s}\n", .{symbol});
    }
    return if (failed) error.PolicyFailure else 0;
}

fn isHex(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn writeAndroidExportsMap(args: []const []const u8) !u8 {
    if (args.len != 1) {
        std.debug.print("usage: jsbay-tool write-android-exports-map <exports.map>\n", .{});
        return error.Usage;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var symbols = try headerSymbols(allocator);
    defer symbols.deinit();
    if (symbols.count() == 0) return error.NoPublicSymbols;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var it = symbols.keyIterator();
    while (it.next()) |sym| try list.append(allocator, sym.*);
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  global:\n");
    for (list.items) |sym| {
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, sym);
        try out.appendSlice(allocator, ";\n");
    }
    try out.appendSlice(allocator, "  local: *;\n};\n");
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = args[0], .data = out.items });
    return 0;
}

pub fn headerSymbols(allocator: std.mem.Allocator) !std.StringHashMap(void) {
    const names = [_][]const u8{ "jsbay.h", "jsbay_bytecode.h", "jsbay_sync.h" };
    var result = std.StringHashMap(void).init(allocator);
    errdefer result.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var include = try std.Io.Dir.cwd().openDir(threaded.io(), "include", .{ .iterate = true });
    defer include.close(threaded.io());
    var iterator = include.iterate();
    while (try iterator.next(threaded.io())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "jsbay") or !std.mem.endsWith(u8, entry.name, ".h")) continue;
        var allowed = false;
        for (names) |name| if (std.mem.eql(u8, name, entry.name)) {
            allowed = true;
            break;
        };
        if (!allowed) return error.UndeclaredPublicHeader;
    }
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ "include", name });
        defer allocator.free(path);
        const text = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(text);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (std.mem.startsWith(u8, text[i..], "/*")) {
                i += (std.mem.indexOf(u8, text[i + 2 ..], "*/") orelse return error.UnterminatedComment) + 3;
                continue;
            }
            if (std.mem.startsWith(u8, text[i..], "//")) {
                i += std.mem.indexOfScalar(u8, text[i..], '\n') orelse (text.len - i);
                continue;
            }
            if (!std.mem.startsWith(u8, text[i..], "jsbay_")) continue;
            if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) continue;
            const start = i;
            i += "jsbay_".len;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) : (i += 1) {}
            const end = i;
            if (std.mem.endsWith(u8, text[start..end], "_t")) continue;
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            if (i < text.len and text[i] == '(') try result.put(try allocator.dupe(u8, text[start..end]), {});
        }
    }
    return result;
}

test "header symbols include functions following jsbay typedef return types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var symbols = try headerSymbols(arena.allocator());
    defer symbols.deinit();
    try std.testing.expect(symbols.contains("jsbay_engine_evaluate"));
    try std.testing.expect(symbols.contains("jsbay_sync_complete"));
}

fn runOutput(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(16 * 1024 * 1024) }) catch return error.ExternalFailure;
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.ExternalFailure;
}

fn requireExternal(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(16 * 1024 * 1024) }) catch |err| {
        std.debug.print("external command failed: {s}\n", .{argv[0]});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("external command failed: {s}\n{s}{s}\n", .{ argv[0], result.stdout, result.stderr });
    return error.ExternalFailure;
}

fn checkDiagnosticExports(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 1) return error.Usage;
    const allocator = init.arena.allocator();
    const report = try std.Io.Dir.cwd().readFileAlloc(init.io, args[0], allocator, .limited(64 * 1024 * 1024));
    const Report = struct { modes: []const struct { name: []const u8, exports: []const []const u8 } };
    const parsed = try std.json.parseFromSlice(Report, allocator, report, .{ .ignore_unknown_fields = true });
    if (parsed.value.modes.len == 0) return error.MissingDiagnosticModes;
    const expected = try headerSymbols(allocator);
    if (expected.count() == 0) return error.MissingPublicDeclarations;
    for (parsed.value.modes) |mode| {
        if (mode.exports.len != expected.count()) return error.DiagnosticExportCountMismatch;
        var seen = std.StringHashMap(void).init(allocator);
        for (mode.exports) |symbol| {
            if (!expected.contains(symbol)) return error.UndeclaredDiagnosticExport;
            if ((try seen.getOrPut(symbol)).found_existing) return error.DuplicateDiagnosticExport;
        }
    }
}

test "JAR class checks reject central-directory signatures outside a valid archive" {
    var fake: [104]u8 = @splat(0);
    @memcpy(fake[0..4], "PK\x01\x02");
    try std.testing.expect(!zipHas(&fake, "missing.class"));
}
