const std = @import("std");

pub fn addOhosMutexIncludes(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) void {
    const abi = target.result.abi;
    if (abi != .ohos and abi != .ohoseabi) return;

    const root = sysroot orelse std.process.fatal("OpenHarmony builds require -Dohos-sysroot=<path-to-sdk-native-sysroot>", .{});
    const triple = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-ohos",
        .x86_64 => "x86_64-linux-ohos",
        .arm => "arm-linux-ohos",
        else => std.process.fatal("unsupported OpenHarmony architecture", .{}),
    };
    module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ root, triple }) });
    module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{root}) });
}

pub fn configureOhosMutex(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) void {
    const abi = target.result.abi;
    if (abi != .ohos and abi != .ohoseabi) return;

    addOhosMutexIncludes(b, module, target, sysroot);
    const header = module.root_source_file.?.dirname().path(b, "ohos_pthread.h");
    const bindings = b.addTranslateC(.{
        .root_source_file = header,
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = false,
    });
    const root = sysroot orelse unreachable;
    const triple = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-ohos",
        .x86_64 => "x86_64-linux-ohos",
        .arm => "arm-linux-ohos",
        else => unreachable,
    };
    bindings.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ root, triple }) });
    bindings.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{root}) });
    module.addImport("ohos_pthread", bindings.createModule());
}
