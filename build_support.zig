const std = @import("std");

/// Link the public module and core with the compiler configuration they require.
pub fn linkConsumer(consumer: *std.Build.Step.Compile, dependency: *std.Build.Dependency) void {
    const core = dependency.artifact("jsbay");
    consumer.root_module.addImport("jsbay", dependency.module("jsbay"));
    consumer.root_module.linkLibrary(core);
    for (core.root_module.include_dirs.items) |include| switch (include) {
        .framework_path => |path| consumer.root_module.addFrameworkPath(path),
        .framework_path_system => |path| consumer.root_module.addSystemFrameworkPath(path),
        else => {},
    };
    for (core.root_module.lib_paths.items) |path| consumer.root_module.addLibraryPath(path);
    if (core.zig_lib_dir) |compiler_lib| {
        consumer.zig_lib_dir = compiler_lib;
        compiler_lib.addStepDependencies(&consumer.step);
    }
}

pub fn linkMathLibrary(module: *std.Build.Module, os: std.Target.Os.Tag) void {
    if (os == .windows) return;
    module.linkSystemLibrary("m", .{});
}
