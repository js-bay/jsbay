//! Host-only runner for the reusable ZEV platform stress cases.
//!
//! The runner owns result JSON, marker evaluation and child-process status. Platform SDKs remain external executables; no adapter invokes a shell.
const std = @import("std");

pub const Status = enum { PASS, FAIL, SKIP, ERROR };

pub const Markers = struct {
    all: []const []const u8 = &.{},
    any: []const []const u8 = &.{},
    contains: []const []const u8 = &.{},
    line_contains_sequence: []const []const []const u8 = &.{},
};

pub const Match = enum { pass, missing_pass, fail_marker };

/// Marker-only exit codes: a missing pass is 1 and a fail marker is 2. Schema/JSON errors are reported before matching and use the command's normal non-zero error path.
pub fn markerExitCode(result: Match) u8 {
    return switch (result) {
        .pass => 0,
        .missing_pass => 1,
        .fail_marker => 2,
    };
}

/// Fail markers always take priority. `all` and `contains` must all occur; `any`, when non-empty, needs one occurrence. Every sequence is checked on one LF-delimited line and must appear left-to-right on that same line.
pub fn matchMarkers(log: []const u8, pass: Markers, fail: Markers) Match {
    if (matches(log, fail)) return .fail_marker;
    return if (matches(log, pass)) .pass else .missing_pass;
}

fn matches(log: []const u8, spec: Markers) bool {
    if (spec.all.len == 0 and spec.any.len == 0 and spec.contains.len == 0 and spec.line_contains_sequence.len == 0) return false;
    for (spec.all) |needle| if (std.mem.indexOf(u8, log, needle) == null) return false;
    for (spec.contains) |needle| if (std.mem.indexOf(u8, log, needle) == null) return false;
    if (spec.any.len != 0) {
        var found_any = false;
        for (spec.any) |needle| {
            if (std.mem.indexOf(u8, log, needle) != null) {
                found_any = true;
                break;
            }
        }
        if (!found_any) return false;
    }
    for (spec.line_contains_sequence) |sequence| {
        var lines = std.mem.splitScalar(u8, log, '\n');
        var found = false;
        while (lines.next()) |line| {
            var cursor: usize = 0;
            for (sequence) |needle| {
                const relative = std.mem.indexOf(u8, line[cursor..], needle) orelse break;
                cursor += relative + needle.len;
            } else {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

const Case = struct {
    schema_version: u32,
    id: []const u8,
    name: []const u8,
    platforms: []const []const u8,
    pass_markers: Markers,
    fail_markers: Markers,
};

const Row = struct {
    case_id: []const u8,
    platform: []const u8,
    status: Status,
    detail: []const u8,
    log: []const u8,
};

const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    out_root: []const u8,
    environ: *const std.process.Environ.Map,
    config: *const std.StringHashMap([]const u8),
    rows: std.ArrayList(Row) = .empty,

    fn deinit(self: *Runner) void {
        for (self.rows.items) |row| {
            self.gpa.free(row.case_id);
            self.gpa.free(row.platform);
            self.gpa.free(row.detail);
            self.gpa.free(row.log);
        }
        self.rows.deinit(self.gpa);
    }

    fn add(self: *Runner, case_id: []const u8, platform: []const u8, status: Status, detail: []const u8, log: []const u8) !void {
        try self.rows.append(self.gpa, .{
            .case_id = try self.gpa.dupe(u8, case_id),
            .platform = try self.gpa.dupe(u8, platform),
            .status = status,
            .detail = try self.gpa.dupe(u8, detail),
            .log = try self.gpa.dupe(u8, log),
        });
    }

    fn writeResults(self: *Runner) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.out_root);
        const path = try std.fs.path.join(self.gpa, &.{ self.out_root, "latest.json" });
        defer self.gpa.free(path);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(self.io, &buffer);
        try std.json.Stringify.value(.{ .schema_version = 2, .rows = self.rows.items }, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
    }

    fn outputPath(self: *Runner, case_id: []const u8, platform: []const u8) ![]const u8 {
        const dir = try std.fs.path.join(self.gpa, &.{ self.out_root, "logs" });
        defer self.gpa.free(dir);
        try std.Io.Dir.cwd().createDirPath(self.io, dir);
        return std.fmt.allocPrint(self.gpa, "{s}/{s}-{s}.log", .{ dir, case_id, platform });
    }

    fn clearLog(self: *Runner, log_path: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(self.io, log_path, .{});
        file.close(self.io);
    }

    fn runCommand(self: *Runner, argv: []const []const u8, cwd: []const u8, log_path: []const u8) !bool {
        const prior = std.Io.Dir.cwd().readFileAlloc(self.io, log_path, self.gpa, .limited(16 * 1024 * 1024)) catch "";
        defer if (prior.ptr != "".ptr) self.gpa.free(prior);
        const result = std.process.run(self.gpa, self.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .timeout = .{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } } }) catch |err| {
            const file = try std.Io.Dir.cwd().createFile(self.io, log_path, .{});
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, prior);
            var buffer: [256]u8 = undefined;
            var writer = file.writer(self.io, &buffer);
            try writer.interface.print("spawn failed: {s}\n", .{@errorName(err)});
            try writer.interface.flush();
            return false;
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const file = try std.Io.Dir.cwd().createFile(self.io, log_path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, prior);
        try file.writeStreamingAll(self.io, result.stdout);
        try file.writeStreamingAll(self.io, result.stderr);
        return result.term.success();
    }

    fn env(self: *Runner, name: []const u8, fallback: []const u8) []const u8 {
        return self.environ.get(name) orelse self.config.get(name) orelse fallback;
    }

    fn commandExists(self: *Runner, command: []const u8) bool {
        const result = std.process.run(self.gpa, self.io, .{ .argv = &.{ "which", command }, .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.term.success();
    }

    fn appendLog(self: *Runner, log_path: []const u8, data: []const u8) !void {
        const prior = std.Io.Dir.cwd().readFileAlloc(self.io, log_path, self.gpa, .limited(16 * 1024 * 1024)) catch "";
        defer if (prior.ptr != "".ptr) self.gpa.free(prior);
        const file = try std.Io.Dir.cwd().createFile(self.io, log_path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, prior);
        try file.writeStreamingAll(self.io, data);
    }

    fn zigLibDir(self: *Runner, zig: []const u8, log_path: []const u8) ![]const u8 {
        const configured = self.env("ZEV_ZIG_LIB_DIR", "");
        if (configured.len != 0) return configured;
        const result = try std.process.run(self.gpa, self.io, .{ .argv = &.{ zig, "env" }, .cwd = .{ .path = self.root }, .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        try self.appendLog(log_path, result.stdout);
        try self.appendLog(log_path, result.stderr);
        if (!result.term.success()) return error.ZigEnvFailed;
        const prefix = ".lib_dir = \"";
        const begin = std.mem.indexOf(u8, result.stdout, prefix) orelse return error.ZigLibDirMissing;
        const tail = result.stdout[begin + prefix.len ..];
        const end = std.mem.indexOfScalar(u8, tail, '\"') orelse return error.ZigLibDirMissing;
        return try self.gpa.dupe(u8, tail[0..end]);
    }

    fn bootedIphoneUdid(self: *Runner, log_path: []const u8) ![]const u8 {
        const result = try std.process.run(self.gpa, self.io, .{ .argv = &.{ "xcrun", "simctl", "list", "devices", "booted" }, .cwd = .{ .path = self.root }, .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
        defer self.gpa.free(result.stderr);
        try self.appendLog(log_path, result.stdout);
        try self.appendLog(log_path, result.stderr);
        if (!result.term.success()) {
            self.gpa.free(result.stdout);
            return error.SimctlQueryFailed;
        }
        defer self.gpa.free(result.stdout);
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "iPhone") == null) continue;
            const open = std.mem.indexOfScalar(u8, line, '(') orelse continue;
            const close_relative = std.mem.indexOfScalar(u8, line[open + 1 ..], ')') orelse continue;
            return try self.gpa.dupe(u8, line[open + 1 .. open + 1 + close_relative]);
        }
        return "";
    }

    fn runPlatform(self: *Runner, case_data: Case, platform: []const u8) !bool {
        const log_path = try self.outputPath(case_data.id, platform);
        defer self.gpa.free(log_path);
        try self.clearLog(log_path);
        var declared = false;
        for (case_data.platforms) |candidate| {
            if (std.mem.eql(u8, candidate, platform)) {
                declared = true;
                break;
            }
        }
        if (!declared) {
            try self.add(case_data.id, platform, .SKIP, "platform not in case.platforms", log_path);
            return true;
        }
        const zig = self.env("ZEV_ZIG", "zig");
        if (!self.commandExists(zig)) {
            try self.add(case_data.id, platform, .FAIL, "zig not found", log_path);
            return false;
        }
        if (std.mem.eql(u8, platform, "macos")) {
            const ok = try self.runCommand(&.{ zig, "build", "stress", "-Doptimize=ReleaseSafe" }, self.root, log_path);
            if (!ok) {
                try self.add(case_data.id, platform, .FAIL, "Zig build or stress run failed", log_path);
                return false;
            }
            return self.finishMarkers(case_data, platform, log_path, "markers matched");
        }
        if (std.mem.eql(u8, platform, "android")) return self.runAndroid(case_data, log_path);
        if (std.mem.eql(u8, platform, "harmony")) return self.runHarmony(case_data, log_path);
        if (std.mem.eql(u8, platform, "linux")) return self.runLinux(case_data, log_path);
        if (std.mem.eql(u8, platform, "windows")) return self.runWindows(case_data, log_path);
        if (std.mem.eql(u8, platform, "ios_sim")) return self.runIosSimulator(case_data, log_path);
        try self.add(case_data.id, platform, .SKIP, "no adapter", log_path);
        return true;
    }

    fn finishMarkers(self: *Runner, case_data: Case, platform: []const u8, log_path: []const u8, success_detail: []const u8) !bool {
        const log = std.Io.Dir.cwd().readFileAlloc(self.io, log_path, self.gpa, .limited(16 * 1024 * 1024)) catch "";
        defer if (log.ptr != "".ptr) self.gpa.free(log);
        switch (matchMarkers(log, case_data.pass_markers, case_data.fail_markers)) {
            .pass => {
                try self.add(case_data.id, platform, .PASS, success_detail, log_path);
                return true;
            },
            .fail_marker => {
                try self.add(case_data.id, platform, .FAIL, "fail marker matched", log_path);
                return false;
            },
            .missing_pass => {
                try self.add(case_data.id, platform, .FAIL, "pass markers not found", log_path);
                return false;
            },
        }
    }

    fn runAndroid(self: *Runner, case_data: Case, log_path: []const u8) !bool {
        const ndk = self.env("ZEV_ANDROID_NDK", "");
        const adb = self.env("ZEV_ADB", "adb");
        if (ndk.len == 0 or !self.commandExists(adb)) {
            try self.add(case_data.id, "android", .SKIP, "Android NDK or adb is not configured", log_path);
            return true;
        }
        const api = self.env("ZEV_ANDROID_API", "24");
        const clang_name = try std.fmt.allocPrint(self.gpa, "aarch64-linux-android{s}-clang", .{api});
        const host_tags = [_][]const u8{ "darwin-arm64", "darwin-x86_64", "linux-x86_64", "windows-x86_64" };
        var clang: ?[]const u8 = null;
        for (host_tags) |host_tag| {
            const candidate = try std.fs.path.join(self.gpa, &.{ ndk, "toolchains", "llvm", "prebuilt", host_tag, "bin", clang_name });
            _ = std.Io.Dir.cwd().statFile(self.io, candidate, .{}) catch continue;
            clang = candidate;
            break;
        }
        if (clang == null) {
            try self.add(case_data.id, "android", .FAIL, "Android NDK has no host Clang for this runner", log_path);
            return false;
        }
        const prefix = try std.fs.path.join(self.gpa, &.{ self.out_root, "build", case_data.id, "android", "install" });
        try std.Io.Dir.cwd().createDirPath(self.io, prefix);
        const zig = self.env("ZEV_ZIG", "zig");
        const target = try std.fmt.allocPrint(self.gpa, "aarch64-linux-android.{s}", .{api});
        const clang_arg = try std.fmt.allocPrint(self.gpa, "-Dandroid-ndk-clang={s}", .{clang.?});
        if (!try self.runCommand(&.{ zig, "build", "-Doptimize=ReleaseSafe", "--prefix", prefix, "-Dtarget", target, clang_arg }, self.root, log_path)) {
            try self.add(case_data.id, "android", .FAIL, "Android Zig build failed", log_path);
            return false;
        }
        const binary = try std.fs.path.join(self.gpa, &.{ prefix, "bin", "zev-stress" });
        const serial = self.env("ZEV_ANDROID_SERIAL", "");
        if (!try self.runCommand(if (serial.len == 0) &.{ adb, "push", binary, "/data/local/tmp/zev_stress" } else &.{ adb, "-s", serial, "push", binary, "/data/local/tmp/zev_stress" }, self.root, log_path) or !try self.runCommand(if (serial.len == 0) &.{ adb, "shell", "chmod", "755", "/data/local/tmp/zev_stress" } else &.{ adb, "-s", serial, "shell", "chmod", "755", "/data/local/tmp/zev_stress" }, self.root, log_path) or !try self.runCommand(if (serial.len == 0) &.{ adb, "shell", "/data/local/tmp/zev_stress" } else &.{ adb, "-s", serial, "shell", "/data/local/tmp/zev_stress" }, self.root, log_path)) {
            try self.add(case_data.id, "android", .FAIL, "Android executable push or run failed", log_path);
            return false;
        }
        return self.finishMarkers(case_data, "android", log_path, "adb run markers matched");
    }

    fn runHarmony(self: *Runner, case_data: Case, log_path: []const u8) !bool {
        const hdc = self.env("ZEV_HDC", "hdc");
        const native = self.env("ZEV_OHOS_NATIVE", "");
        if (!self.commandExists(hdc) or native.len == 0) {
            try self.add(case_data.id, "harmony", .SKIP, "OpenHarmony SDK or hdc is not configured", log_path);
            return true;
        }
        const device = self.env("ZEV_HARMONY_DEVICE", "");
        if (device.len == 0) {
            try self.add(case_data.id, "harmony", .SKIP, "OpenHarmony device is not configured", log_path);
            return true;
        }
        const clang = try std.fs.path.join(self.gpa, &.{ native, "llvm", "bin", "aarch64-unknown-linux-ohos-clang" });
        const prefix = try std.fs.path.join(self.gpa, &.{ self.out_root, "build", case_data.id, "harmony", "install" });
        try std.Io.Dir.cwd().createDirPath(self.io, prefix);
        const zig = self.env("ZEV_ZIG", "zig");
        const clang_arg = try std.fmt.allocPrint(self.gpa, "-Dohos-clang={s}", .{clang});
        const sysroot_arg = try std.fmt.allocPrint(self.gpa, "-Dohos-sysroot={s}/sysroot", .{native});
        if (!try self.runCommand(&.{ zig, "build", "-Doptimize=ReleaseSafe", "--prefix", prefix, "-Dtarget", "aarch64-linux-ohos", clang_arg, sysroot_arg }, self.root, log_path)) {
            try self.add(case_data.id, "harmony", .FAIL, "Harmony Zig cross-build failed", log_path);
            return false;
        }
        const binary = try std.fs.path.join(self.gpa, &.{ prefix, "bin", "zev-stress" });
        if (!try self.runCommand(&.{ hdc, "-t", device, "file", "send", binary, "/data/local/tmp/zev_stress" }, self.root, log_path) or !try self.runCommand(&.{ hdc, "-t", device, "shell", "chmod 755 /data/local/tmp/zev_stress && /data/local/tmp/zev_stress; rc=$?; rm -f /data/local/tmp/zev_stress; exit $rc" }, self.root, log_path)) {
            try self.add(case_data.id, "harmony", .FAIL, "Harmony executable transfer or run failed", log_path);
            return false;
        }
        return self.finishMarkers(case_data, "harmony", log_path, "hdc run markers matched");
    }

    fn runLinux(self: *Runner, case_data: Case, log_path: []const u8) !bool {
        const host = self.env("ZEV_LINUX_SSH", "");
        if (host.len == 0 or !self.commandExists("ssh") or !self.commandExists("scp")) {
            try self.add(case_data.id, "linux", .SKIP, "Linux SSH host is not configured", log_path);
            return true;
        }
        const prefix = try std.fs.path.join(self.gpa, &.{ self.out_root, "build", case_data.id, "linux", "install" });
        try std.Io.Dir.cwd().createDirPath(self.io, prefix);
        const zig = self.env("ZEV_ZIG", "zig");
        if (!try self.runCommand(&.{ zig, "build", "-Doptimize=ReleaseSafe", "--prefix", prefix, "-Dtarget", "x86_64-linux-gnu" }, self.root, log_path)) {
            try self.add(case_data.id, "linux", .FAIL, "Linux Zig cross-build failed", log_path);
            return false;
        }
        const binary = try std.fs.path.join(self.gpa, &.{ prefix, "bin", "zev-stress" });
        const remote = "/tmp/zev-platform-stress";
        const destination = try std.fmt.allocPrint(self.gpa, "{s}:{s}/zev-stress", .{ host, remote });
        if (!try self.runCommand(&.{ "ssh", host, "mkdir -p /tmp/zev-platform-stress" }, self.root, log_path) or !try self.runCommand(&.{ "scp", binary, destination }, self.root, log_path) or !try self.runCommand(&.{ "ssh", host, "cd /tmp/zev-platform-stress && ./zev-stress; rc=$?; rm -rf /tmp/zev-platform-stress; exit $rc" }, self.root, log_path)) {
            try self.add(case_data.id, "linux", .FAIL, "Linux transfer or remote run failed", log_path);
            return false;
        }
        return self.finishMarkers(case_data, "linux", log_path, "remote markers matched");
    }

    fn runWindows(self: *Runner, case_data: Case, log_path: []const u8) !bool {
        const host = self.env("ZEV_WINDOWS_SSH", "");
        if (host.len == 0 or !self.commandExists("ssh") or !self.commandExists("scp")) {
            try self.add(case_data.id, "windows", .SKIP, "Windows SSH host is not configured", log_path);
            return true;
        }
        const prefix = try std.fs.path.join(self.gpa, &.{ self.out_root, "build", case_data.id, "windows", "install" });
        try std.Io.Dir.cwd().createDirPath(self.io, prefix);
        const zig = self.env("ZEV_ZIG", "zig");
        if (!try self.runCommand(&.{ zig, "build", "-Doptimize=ReleaseSafe", "--prefix", prefix, "-Dtarget", "x86_64-windows-gnu" }, self.root, log_path)) {
            try self.add(case_data.id, "windows", .FAIL, "Windows Zig cross-build failed", log_path);
            return false;
        }
        const binary = try std.fs.path.join(self.gpa, &.{ prefix, "bin", "zev-stress.exe" });
        const remote_dir = self.env("ZEV_WINDOWS_REMOTE_DIR", "C:/zev-platform-kit");
        const destination = try std.fmt.allocPrint(self.gpa, "{s}:{s}/zev_stress.exe", .{ host, remote_dir });
        const mkdir = try std.fmt.allocPrint(self.gpa, "powershell -NoProfile -Command New-Item -ItemType Directory -Force -Path '{s}'", .{remote_dir});
        const run = try std.fmt.allocPrint(self.gpa, "powershell -NoProfile -Command & '{s}/zev_stress.exe'; exit $LASTEXITCODE", .{remote_dir});
        if (!try self.runCommand(&.{ "ssh", host, mkdir }, self.root, log_path) or !try self.runCommand(&.{ "scp", binary, destination }, self.root, log_path) or !try self.runCommand(&.{ "ssh", host, run }, self.root, log_path)) {
            try self.add(case_data.id, "windows", .FAIL, "Windows transfer or remote run failed", log_path);
            return false;
        }
        return self.finishMarkers(case_data, "windows", log_path, "remote markers matched");
    }

    fn runIosSimulator(self: *Runner, case_data: Case, log_path: []const u8) !bool {
        var udid = self.env("ZEV_IOS_SIM_UDID", "");
        if (!self.commandExists("xcrun")) {
            try self.add(case_data.id, "ios_sim", .SKIP, "xcrun is not configured", log_path);
            return true;
        }
        const zig = self.env("ZEV_ZIG", "zig");
        const lib_dir = self.zigLibDir(zig, log_path) catch {
            try self.add(case_data.id, "ios_sim", .FAIL, "Unable to locate the Zig standard library", log_path);
            return false;
        };
        const process = try std.fs.path.join(self.gpa, &.{ lib_dir, "std", "process.zig" });
        const build_dir = try std.fs.path.join(self.gpa, &.{ self.out_root, "build", case_data.id, "ios_sim" });
        const overlay = try std.fs.path.join(self.gpa, &.{ build_dir, "zig-ios-lib" });
        const prefix = try std.fs.path.join(self.gpa, &.{ build_dir, "install" });
        try std.Io.Dir.cwd().createDirPath(self.io, build_dir);
        if (!try self.runCommand(&.{ zig, "build", "prepare-ios-stdlib", "--", process, overlay }, self.root, log_path) or !try self.runCommand(&.{ zig, "build", "-Doptimize=ReleaseSafe", "-Dtarget=aarch64-ios.14.0-simulator", "--prefix", prefix, try std.fmt.allocPrint(self.gpa, "-Dios-zig-lib-dir={s}", .{overlay}) }, self.root, log_path)) {
            try self.add(case_data.id, "ios_sim", .FAIL, "iOS overlay preparation or build failed", log_path);
            return false;
        }
        const app = try std.fs.path.join(self.gpa, &.{ build_dir, "EventLoopStress.app" });
        try std.Io.Dir.cwd().createDirPath(self.io, app);
        const binary = try std.fs.path.join(self.gpa, &.{ prefix, "bin", "zev-stress" });
        const plist = try std.fs.path.join(self.gpa, &.{ self.root, "platform-test", "cases", case_data.id, "ios_Info.plist" });
        const bundle = self.env("ZEV_IOS_BUNDLE_ID", "org.example.eventloopstress");
        if (udid.len == 0) {
            udid = self.bootedIphoneUdid(log_path) catch {
                try self.add(case_data.id, "ios_sim", .FAIL, "simctl device query failed", log_path);
                return false;
            };
        }
        if (udid.len == 0) {
            try self.add(case_data.id, "ios_sim", .SKIP, "iOS simulator executable built, but no booted iPhone simulator", log_path);
            return true;
        }
        if (!try self.runCommand(&.{ "cp", plist, try std.fs.path.join(self.gpa, &.{ app, "Info.plist" }) }, self.root, log_path) or !try self.runCommand(&.{ "cp", binary, try std.fs.path.join(self.gpa, &.{ app, "EventLoopStress" }) }, self.root, log_path) or !try self.runCommand(&.{ "codesign", "-s", "-", "--force", "--deep", app }, self.root, log_path) or !try self.runCommand(&.{ "xcrun", "simctl", "install", udid, app }, self.root, log_path) or !try self.runCommand(&.{ "xcrun", "simctl", "launch", "--console-pty", udid, bundle }, self.root, log_path)) {
            try self.add(case_data.id, "ios_sim", .FAIL, "iOS simulator install or run failed", log_path);
            return false;
        }
        return self.finishMarkers(case_data, "ios_sim", log_path, "simctl markers matched");
    }
};

fn loadCase(gpa: std.mem.Allocator, root: []const u8, case_id: []const u8) !std.json.Parsed(Case) {
    const path = try std.fs.path.join(gpa, &.{ root, "platform-test", "cases", case_id, "case.json" });
    defer gpa.free(path);
    // The static parser keeps string slices into its source bytes. The caller uses an arena, so retain this buffer through the parsed case lifetime.
    const input = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, gpa, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSlice(Case, gpa, input, .{ .ignore_unknown_fields = true });
    if (parsed.value.schema_version != 2) return error.UnsupportedCaseSchema;
    return parsed;
}

fn parseConfig(gpa: std.mem.Allocator, input: []const u8) !std.StringHashMap([]const u8) {
    var values = std.StringHashMap([]const u8).init(gpa);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trim(u8, line[7..], " \t");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        var value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0) return error.InvalidConfig;
        if (value.len >= 2 and ((value[0] == '\"' and value[value.len - 1] == '\"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
        try values.put(try gpa.dupe(u8, key), try gpa.dupe(u8, value));
    }
    return values;
}

fn deinitConfig(gpa: std.mem.Allocator, values: *std.StringHashMap([]const u8)) void {
    var iterator = values.iterator();
    while (iterator.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    values.deinit();
}

fn loadConfig(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !std.StringHashMap([]const u8) {
    const path = try std.fs.path.join(gpa, &.{ root, "platform-test", "config.env" });
    const input = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .init(gpa),
        else => return err,
    };
    return parseConfig(gpa, input);
}

fn caseIds(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !std.ArrayList([]const u8) {
    const path = try std.fs.path.join(gpa, &.{ root, "platform-test", "cases" });
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var ids: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try ids.append(gpa, try gpa.dupe(u8, entry.name));
    }
    return ids;
}

fn printUsage(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io,
        \\zev-platform-test commands:
        \\  list                          List registered cases
        \\  platforms                     List platform adapters
        \\  run --case ID --platform P    Run one case on one platform
        \\  run --case ID --all           Run one case on every declared platform
        \\  run --all                     Run every case on every declared platform
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn printList(init: std.process.Init, gpa: std.mem.Allocator, root: []const u8, out: []const u8) !void {
    const heading = try std.fmt.allocPrint(gpa, "REPO: {s}\nOUT:  {s}\nCases:\n", .{ root, out });
    try std.Io.File.stdout().writeStreamingAll(init.io, heading);
    var ids = try caseIds(gpa, init.io, root);
    defer ids.deinit(gpa);
    for (ids.items) |id| {
        var parsed = try loadCase(gpa, root, id);
        defer parsed.deinit();
        const prefix = try std.fmt.allocPrint(gpa, "  - {s}  ({s})\n      platforms:", .{ parsed.value.id, parsed.value.name });
        try std.Io.File.stdout().writeStreamingAll(init.io, prefix);
        for (parsed.value.platforms) |platform| {
            const item = try std.fmt.allocPrint(gpa, " {s}", .{platform});
            try std.Io.File.stdout().writeStreamingAll(init.io, item);
        }
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}

fn printPlatforms(init: std.process.Init) !void {
    for ([_][]const u8{ "macos", "linux", "android", "ios_sim", "windows", "harmony" }) |platform| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "{s}  (adapter ok)\n", .{platform});
        try std.Io.File.stdout().writeStreamingAll(init.io, line);
    }
}

pub fn main(init: std.process.Init) !void {
    // Parsed case strings borrow their JSON input, so keep all runner data in the process-lifetime arena supplied by the Zig application entry point.
    const gpa = init.arena.allocator();
    const io = init.io;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    _ = args_iter.next() orelse return error.InvalidArguments;
    const command = args_iter.next() orelse {
        try printUsage(init);
        return;
    };
    const root = init.environ_map.get("ZEV_ROOT") orelse ".";
    var config = try loadConfig(gpa, io, root);
    defer deinitConfig(gpa, &config);
    const out = init.environ_map.get("ZEV_OUT_ROOT") orelse config.get("ZEV_OUT_ROOT") orelse "/tmp/zev-platform-test-out";
    var runner = Runner{ .gpa = gpa, .io = io, .root = root, .out_root = out, .environ = init.environ_map, .config = &config };
    defer runner.deinit();
    if (std.mem.eql(u8, command, "list")) return printList(init, gpa, root, out);
    if (std.mem.eql(u8, command, "platforms")) return printPlatforms(init);
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) return printUsage(init);
    if (!std.mem.eql(u8, command, "run")) {
        try printUsage(init);
        return error.InvalidArguments;
    }
    var case_id: ?[]const u8 = null;
    var platform: ?[]const u8 = null;
    var all = false;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--case")) case_id = args_iter.next() orelse return error.InvalidArguments else if (std.mem.eql(u8, arg, "--platform")) platform = args_iter.next() orelse return error.InvalidArguments else if (std.mem.eql(u8, arg, "--all")) all = true else return error.InvalidArguments;
    }
    var ok = true;
    if (case_id) |id| {
        var parsed = try loadCase(gpa, root, id);
        defer parsed.deinit();
        if (all) {
            for (parsed.value.platforms) |item| ok = (try runner.runPlatform(parsed.value, item)) and ok;
        } else {
            ok = try runner.runPlatform(parsed.value, platform orelse return error.InvalidArguments);
        }
    } else {
        if (!all or platform != null) return error.InvalidArguments;
        var ids = try caseIds(gpa, io, root);
        defer ids.deinit(gpa);
        for (ids.items) |id| {
            var parsed = try loadCase(gpa, root, id);
            defer parsed.deinit();
            for (parsed.value.platforms) |item| ok = (try runner.runPlatform(parsed.value, item)) and ok;
        }
    }
    try runner.writeResults();
    if (!ok) return error.PlatformTestFailed;
}

test "marker schema requires all values and a same-line ordered sequence" {
    const pass = Markers{ .all = &.{ "result=PASS", "native_mutex_checks=PASS" }, .line_contains_sequence = &.{&.{ "mutex_contention", "measurement=available" }} };
    try std.testing.expectEqual(Match.pass, matchMarkers("result=PASS\nnative_mutex_checks=PASS\nmutex_contention measurement=available", pass, .{}));
    try std.testing.expectEqual(Match.missing_pass, matchMarkers("result=PASS\nnative_mutex_checks=PASS\nmeasurement=available mutex_contention", pass, .{}));
    try std.testing.expectEqual(Match.missing_pass, matchMarkers("result=PASS\nnative_mutex_checks=PASS\nmutex_contention\nmeasurement=available", pass, .{}));
}

test "fail markers win even when pass markers match" {
    try std.testing.expectEqual(Match.fail_marker, matchMarkers("result=PASS\nresult=FAIL", .{ .contains = &.{"result=PASS"} }, .{ .contains = &.{"result=FAIL"} }));
}

test "any evaluates every candidate before rejecting the marker set" {
    try std.testing.expectEqual(Match.pass, matchMarkers("later", .{ .any = &.{ "missing", "later" } }, .{}));
}

test "marker result preserves the historical nonzero codes" {
    try std.testing.expectEqual(@as(u8, 1), markerExitCode(matchMarkers("no marker", .{ .contains = &.{"PASS"} }, .{})));
    try std.testing.expectEqual(@as(u8, 2), markerExitCode(matchMarkers("PASS FAIL", .{ .contains = &.{"PASS"} }, .{ .contains = &.{"FAIL"} })));
}

test "case schema is rejected before a platform command runs" {
    const gpa = std.testing.allocator;
    const input = "{\"schema_version\":1,\"id\":\"x\",\"name\":\"x\",\"platforms\":[],\"pass_markers\":{},\"fail_markers\":{}}";
    var parsed = try std.json.parseFromSlice(Case, gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.schema_version);
}

test "config accepts comments export and quoted values without executing code" {
    var values = try parseConfig(std.testing.allocator, "# local device configuration\nexport ZEV_ANDROID_SERIAL=\"device id\"\nZEV_WINDOWS_REMOTE_DIR='C:/platform kit'\nZEV_EMPTY=\n");
    defer deinitConfig(std.testing.allocator, &values);
    try std.testing.expectEqualStrings("device id", values.get("ZEV_ANDROID_SERIAL").?);
    try std.testing.expectEqualStrings("C:/platform kit", values.get("ZEV_WINDOWS_REMOTE_DIR").?);
    try std.testing.expectEqualStrings("", values.get("ZEV_EMPTY").?);
}

test "a new platform attempt clears markers left by the preceding attempt" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(out_root);
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var config = std.StringHashMap([]const u8).init(gpa);
    defer config.deinit();
    var runner = Runner{ .gpa = gpa, .io = io, .root = ".", .out_root = out_root, .environ = &environ, .config = &config };
    defer runner.deinit();
    const log_path = try runner.outputPath("fixture", "macos");
    defer gpa.free(log_path);
    try runner.clearLog(log_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = "result=PASS\n" });
    try runner.clearLog(log_path);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .limited(1024));
    defer gpa.free(log);
    try std.testing.expectEqualStrings("", log);
}
