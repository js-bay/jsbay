const std = @import("std");
const zev_build = @import("zev");

const quickjs_root = "vendor/quickjs";
const quickjs_ng_root = "vendor/quickjs-ng";

pub const Backend = enum {
    quickjs_ng,
    quickjs,
    jsc,
    escargot,
    hermes,
};

/// Link the public module and core with the compiler configuration they require.
pub fn linkConsumer(consumer: *std.Build.Step.Compile, dependency: *std.Build.Dependency) void {
    const core = dependency.artifact("js_bay");
    consumer.root_module.addImport("js_bay", dependency.module("js_bay"));
    consumer.root_module.linkLibrary(core);
    for (core.root_module.include_dirs.items) |include| switch (include) {
        .framework_path => |path| consumer.root_module.addFrameworkPath(path),
        .framework_path_system => |path| consumer.root_module.addSystemFrameworkPath(path),
        else => {},
    };
    if (core.zig_lib_dir) |compiler_lib| {
        consumer.zig_lib_dir = compiler_lib;
        compiler_lib.addStepDependencies(&consumer.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Repository-maintenance commands always run on the build host.  They must never inherit `-Dtarget`, because Apple/Android artifacts are not executable by the machine orchestrating their build.
    const tool = b.addExecutable(.{
        .name = "jsbay-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/src/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const install_tool = b.addInstallArtifact(tool, .{});
    b.getInstallStep().dependOn(&install_tool.step);
    b.step("install-tool", "Install the host-native repository tool").dependOn(&install_tool.step);
    const tool_run = b.addRunArtifact(tool);
    tool_run.addPassthruArgs();
    b.step("tool", "Run a host-native repository tool").dependOn(&tool_run.step);
    const tool_test_options = b.addOptions();
    tool_test_options.addOptionPath("executable", tool.getEmittedBin());
    const tool_test_module = b.createModule(.{
        .root_source_file = b.path("tools/src/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    tool_test_module.addOptions("tool_options", tool_test_options);
    const tool_tests = b.addTest(.{ .root_module = tool_test_module });
    const run_tool_tests = b.addRunArtifact(tool_tests);
    run_tool_tests.step.dependOn(&install_tool.step);
    b.step("test-tools", "Run repository-tool tests").dependOn(&run_tool_tests.step);

    const backend = b.option(Backend, "backend", "JS engine backend (quickjs_ng, quickjs, jsc, escargot, or hermes)") orelse .quickjs_ng;
    const quickjs_gc_stress = b.option(bool, "quickjs-gc-stress", "Force a QuickJS GC before every allocation (QuickJS-NG or QuickJS only)") orelse false;
    const shared = b.option(bool, "shared", "Build shared library instead of static") orelse false;
    const apple_sysroot = b.option([]const u8, "apple-sysroot", "Apple SDK sysroot path for cross-compilation");
    const library_only = b.option(bool, "library-only", "Build/install the library without host-only benchmark or demo executables") orelse false;
    const inspector_enabled = b.option(bool, "inspector", "Include the CDP inspector and source-debugger hooks") orelse true;
    const requested_inspector_transport = b.option(bool, "inspector-transport", "Include the optional HTTP/WebSocket inspector transport") orelse true;
    const inspector_transport_enabled = inspector_enabled and requested_inspector_transport;
    const requested_heap_snapshot = b.option(bool, "heap-snapshot", "Include QuickJS heap-reference snapshots") orelse true;
    const heap_snapshot = inspector_enabled and requested_heap_snapshot;
    const bytecode_cache_enabled = b.option(bool, "bytecode-cache", "Include persistent bytecode-cache reads and writes") orelse true;
    const stress_tests = b.option(bool, "stress-tests", "Run tests whose names include stress, including high-load event-loop and timer tests") orelse false;
    // Test-only: exports js_bay_test_trigger_native_fault. NEVER enable for publish / library-only ReleaseFast product builds.
    const fault_injection = b.option(bool, "fault-injection", "Export test-only native fault probe (js_bay_test_trigger_native_fault); default OFF") orelse false;
    const asan = b.option(bool, "asan", "Compile QuickJS/NG C sources with -fsanitize=address for harsh ASan consumers") orelse false;
    const apple_package = b.option(bool, "apple-package", "Build a stripped Apple XCFramework library without Zig error tracing") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const android_sysroot = b.option([]const u8, "android-sysroot", "NDK sysroot whose usr/include provides Bionic headers");
    const android_lib_dir = b.option([]const u8, "android-lib-dir", "Directory of static stubs Zig can resolve while linking a static archive. The NDK clang step links the real Bionic libraries.");
    const ohos_sysroot = b.option([]const u8, "ohos-sysroot", "OpenHarmony native sysroot (the native/sysroot directory from the SDK)");

    const escargot_install_opt = b.option([]const u8, "escargot-install", "Escargot install prefix (default vendor/escargot-install)");
    const hermes_install_opt = b.option([]const u8, "hermes-install", "Hermes install prefix (default vendor/hermes-install)");
    const libstdcxx_opt = b.option([]const u8, "libstdcxx", "Absolute path to libstdc++.a (else JSBAY_LIBSTDCXX); required for -Dbackend=escargot|hermes");
    const icu_lib_dir_opt = b.option([]const u8, "icu-lib-dir", "Directory with libicuuc/icui18n/icudata (else JSBAY_ICU_LIB_DIR); required for -Dbackend=hermes");
    // Hermes create-time GCConfig.MaxHeapSize default when EngineConfig.max_heap_size==0. 0 = Hermes built-in default (3GiB).
    const hermes_max_heap = b.option(u64, "hermes-max-heap", "Hermes create-time MaxHeapSize bytes (0=Hermes default 3GiB); EngineConfig.max_heap_size overrides") orelse 0;

    const os = target.result.os.tag;
    const ohos = target.result.abi == .ohos or target.result.abi == .ohoseabi;

    if (quickjs_gc_stress and backend != .quickjs_ng and backend != .quickjs) {
        std.process.fatal("-Dquickjs-gc-stress=true requires -Dbackend=quickjs_ng or -Dbackend=quickjs", .{});
    }
    if (fault_injection and apple_package) {
        std.process.fatal("-Dfault-injection=true must not be combined with -Dapple-package (product packaging)", .{});
    }

    const spike_libstdcxx: ?[]const u8 = libstdcxx_opt orelse b.graph.environ_map.get("JSBAY_LIBSTDCXX");
    const spike_icu_lib_dir: ?[]const u8 = icu_lib_dir_opt orelse b.graph.environ_map.get("JSBAY_ICU_LIB_DIR");
    const spike_escargot_install: []const u8 = escargot_install_opt orelse "vendor/escargot-install";
    const spike_hermes_install: []const u8 = hermes_install_opt orelse "vendor/hermes-install";
    if ((backend == .escargot or backend == .hermes) and spike_libstdcxx == null) {
        std.process.fatal("-Dbackend={s} needs -Dlibstdcxx=/path/to/libstdc++.a or JSBAY_LIBSTDCXX (g++ local-exec TLS; Zig must not use libc++)", .{@tagName(backend)});
    }
    if (backend == .hermes and spike_icu_lib_dir == null) {
        std.process.fatal("-Dbackend=hermes needs -Dicu-lib-dir=/path/to/icu/lib or JSBAY_ICU_LIB_DIR", .{});
    }

    const zev_dep = b.dependency("zev", .{
        .target = target,
        .optimize = optimize,
    });
    const zev = zev_dep.module("zev");
    zev_build.build_support_api.configureOhosMutex(b, zev, target, ohos_sysroot);
    const js_event_loop_dep = b.dependency("js_event_loop", .{ .target = target, .optimize = optimize });
    const js_event_loop = js_event_loop_dep.module("js_event_loop");
    const inspector_dep = b.dependency("inspector", .{ .target = target, .optimize = optimize });
    const inspector = inspector_dep.module("inspector");
    const inspector_transport_dep = b.dependency("inspector_transport", .{ .target = target, .optimize = optimize });
    const inspector_transport = inspector_transport_dep.module("inspector_transport");
    const bytecode_cache_dep = b.dependency("bytecode_cache", .{ .target = target, .optimize = optimize });
    const bytecode_cache = bytecode_cache_dep.module("bytecode_cache");

    // The checked-in gitlinks are copied into the build cache before patching, leaving both the submodule checkout and an imported source snapshot intact.
    const qjs_root: ?std.Build.LazyPath = switch (backend) {
        .quickjs_ng => preparePatchedQuickJsNg(b, tool),
        .quickjs => preparePatchedQuickJs(b, tool),
        .jsc => null,
        .escargot, .hermes => null,
    };

    // Build options module passed to source code
    const build_options = b.addOptions();
    build_options.addOption(Backend, "backend", backend);
    build_options.addOption(u32, "packed_backend_bits", 0); // mono backend builds
    build_options.addOption(bool, "stress_tests", stress_tests);
    build_options.addOption(bool, "inspector", inspector_enabled);
    build_options.addOption(bool, "inspector_transport", inspector_transport_enabled);
    build_options.addOption(bool, "heap_snapshot", heap_snapshot);
    build_options.addOption(bool, "bytecode_cache", bytecode_cache_enabled);
    build_options.addOption(bool, "fault_injection", fault_injection);
    build_options.addOption(u64, "hermes_max_heap", hermes_max_heap);
    build_options.addOption([]const u8, "bytecode_fingerprint", bytecodeFingerprint(b, target.result, backend, optimize, quickjs_gc_stress, inspector_enabled, heap_snapshot));

    // Translate quickjs.h once and import it as "qjs".
    const qjs_mod = if (qjs_root) |root| blk: {
        const android = target.result.abi.isAndroid();
        const header = if (backend == .quickjs_ng)
            root.path(b, "quickjs.h")
        else
            b.path("src/backend/quickjs/quickjs_shim.h");
        const translate_c = b.addTranslateC(.{
            .root_source_file = header,
            .target = target,
            .optimize = optimize,
            // -lc on a Darwin host appends the macOS SDK, causing Bionic limits.h to include_next into that SDK and fail translation.
            .link_libc = !android and !ohos,
        });
        translate_c.defineCMacro("JS_BAY_INSPECTOR", if (inspector_enabled) "1" else "0");
        translate_c.defineCMacro("JS_BAY_HEAP_SNAPSHOT", if (heap_snapshot) "1" else "0");
        translate_c.addIncludePath(root);
        if (android) {
            if (android_sysroot) |sysroot| {
                const triple = androidLibTriple(target.result.cpu.arch);
                translate_c.addSystemIncludePath(.{
                    .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }),
                });
                translate_c.addSystemIncludePath(.{
                    .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}),
                });
                // The host SDK can still sit later on the search path. This header ends the limits.h include_next chain before it.
                const limits_stub = b.addWriteFiles();
                _ = limits_stub.add("limits.h",
                    \\#ifndef JS_BAY_ANDROID_LIMITS_STUB_H
                    \\#define JS_BAY_ANDROID_LIMITS_STUB_H
                    \\#endif
                    \\
                );
                translate_c.addSystemIncludePath(limits_stub.getDirectory());
            }
        }
        if (ohos) {
            if (ohos_sysroot) |sysroot| {
                const triple = ohosLibTriple(target.result.cpu.arch);
                translate_c.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }) });
                translate_c.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
            }
        }
        break :blk translate_c.createModule();
    } else null;

    // --- Library (static or shared) ---
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .strip = if (apple_package) true else null,
        .error_tracing = if (apple_package) false else null,
    });
    lib_module.addOptions("build_options", build_options);
    if (qjs_mod) |qjs| lib_module.addImport("qjs", qjs);
    if (target.result.abi.isAndroid()) {
        if (android_sysroot) |sysroot| {
            const api = target.result.os.version_range.linux.android;
            const triple = androidLibTriple(target.result.cpu.arch);
            // Use the NDK sysroot so native bridges and QuickJS see errno.h and libm from the same API level the .so is linked against.
            lib_module.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }),
            });
            lib_module.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}),
            });
            // A real NDK libm.so in this path gets archived into the static library and corrupts the shared object. Callers pass a directory that contains a static stub instead.
            if (android_lib_dir) |lib_dir| {
                lib_module.addLibraryPath(.{ .cwd_relative = lib_dir });
            } else {
                lib_module.addLibraryPath(.{
                    .cwd_relative = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, api }),
                });
            }
        }
    }

    if (ohos) {
        if (ohos_sysroot) |sysroot| {
            const triple = ohosLibTriple(target.result.cpu.arch);
            lib_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }) });
            lib_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
            lib_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}", .{ sysroot, triple }) });
        }
    }

    // Apple sysroot for cross-compilation (iOS, iOS Simulator, cross-macOS)
    if (apple_sysroot) |sysroot| {
        const sysroot_include = b.fmt("{s}/usr/include", .{sysroot});
        lib_module.addSystemIncludePath(.{ .cwd_relative = sysroot_include });
        lib_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sysroot}) });
    }

    lib_module.addImport("zev", zev);
    lib_module.addImport("js_event_loop", js_event_loop);
    lib_module.addImport("inspector", inspector);
    lib_module.addImport("inspector_transport", inspector_transport);
    lib_module.addImport("bytecode_cache", bytecode_cache);
    addPlatformCompatSources(b, lib_module);
    addBackendSources(b, lib_module, backend, quickjs_gc_stress, os, qjs_root, inspector_enabled, heap_snapshot, asan, spike_escargot_install, spike_hermes_install, spike_libstdcxx, spike_icu_lib_dir);

    lib_module.linkSystemLibrary("m", .{});
    const lib = b.addLibrary(.{
        .name = "js_bay",
        .root_module = lib_module,
        .linkage = if (shared) .dynamic else .static,
        .zig_lib_dir = if (os == .ios) prepareIosStdlib(b, tool) else null,
    });
    if (!shared and (os.isDarwin() or (os == .linux and !target.result.abi.isAndroid() and !ohos)))
        lib.bundle_compiler_rt = true;
    b.installArtifact(lib);

    // Install C header
    b.installFile("include/js_bay.h", "include/js_bay.h");
    for ([_][]const u8{ "js_bay_bytecode.h", "js_bay_sync.h", "module.modulemap" }) |header| {
        b.installFile(b.fmt("include/{s}", .{header}), b.fmt("include/{s}", .{header}));
    }

    // --- Zig module for consumers ---
    const mod = b.addModule("js_bay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);
    mod.addImport("zev", zev);
    mod.addImport("js_event_loop", js_event_loop);
    mod.addImport("inspector", inspector);
    mod.addImport("inspector_transport", inspector_transport);
    mod.addImport("bytecode_cache", bytecode_cache);
    if (qjs_mod) |qjs| mod.addImport("qjs", qjs);
    if (qjs_root) |root| mod.addIncludePath(root);

    // Demos and benchmarks use this repository-private implementation module. It stays out of the public `js_bay` module so product consumers use the typed C ABI or the documented Zig expert modules instead.
    const internal_tools_module = b.createModule(.{
        .root_source_file = b.path("src/internal_tools.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    internal_tools_module.addOptions("build_options", build_options);
    internal_tools_module.addImport("zev", zev);
    internal_tools_module.addImport("js_event_loop", js_event_loop);
    internal_tools_module.addImport("inspector", inspector);
    internal_tools_module.addImport("inspector_transport", inspector_transport);
    internal_tools_module.addImport("bytecode_cache", bytecode_cache);
    if (qjs_mod) |qjs| internal_tools_module.addImport("qjs", qjs);
    if (qjs_root) |root| internal_tools_module.addIncludePath(root);

    // --- Unit tests ---
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addOptions("build_options", build_options);
    test_module.addImport("zev", zev);
    test_module.addImport("js_event_loop", js_event_loop);
    test_module.addImport("inspector", inspector);
    test_module.addImport("inspector_transport", inspector_transport);
    test_module.addImport("bytecode_cache", bytecode_cache);
    if (qjs_mod) |qjs| test_module.addImport("qjs", qjs);

    addPlatformCompatSources(b, test_module);
    addBackendSources(b, test_module, backend, quickjs_gc_stress, os, qjs_root, inspector_enabled, heap_snapshot, asan, spike_escargot_install, spike_hermes_install, spike_libstdcxx, spike_icu_lib_dir);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .filters = if (stress_tests) &.{"stress"} else if (test_filter) |filter| &.{filter} else &.{},
        // Escargot/gcc TLSDESC needs GNU ld; lld mishandles _TLS_MODULE_BASE_/thread_local from libescargot.a
        .use_lld = false,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run js-bay unit tests");
    test_step.dependOn(&run_unit_tests.step);
    b.step("test-engine", "Run engine tests without independent package suites").dependOn(&run_unit_tests.step);
    b.step("test-compile", "Compile engine tests without running them").dependOn(&unit_tests.step);
    if (!stress_tests) {
        const zev_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = zev_dep.path("src/tests.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "zev", .module = zev }},
            }),
            .filters = if (test_filter) |filter| &.{filter} else &.{},
        });
        test_step.dependOn(&b.addRunArtifact(zev_tests).step);
        const js_event_loop_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = js_event_loop_dep.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "js_event_loop", .module = js_event_loop },
                .{ .name = "zev", .module = zev },
            },
        }), .filters = if (test_filter) |filter| &.{filter} else &.{} });
        test_step.dependOn(&b.addRunArtifact(js_event_loop_tests).step);
        const inspector_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = inspector_dep.path("src/tests.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "inspector", .module = inspector }},
            }),
            .filters = if (test_filter) |filter| &.{filter} else &.{},
        });
        test_step.dependOn(&b.addRunArtifact(inspector_tests).step);
        const transport_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = inspector_transport_dep.path("src/tests.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "inspector_transport", .module = inspector_transport },
                    .{ .name = "zev", .module = zev },
                },
            }),
            .filters = if (test_filter) |filter| &.{filter} else &.{},
        });
        test_step.dependOn(&b.addRunArtifact(transport_tests).step);
        const bytecode_cache_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = bytecode_cache_dep.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "bytecode_cache", .module = bytecode_cache }},
        }), .filters = if (test_filter) |filter| &.{filter} else &.{} });
        test_step.dependOn(&b.addRunArtifact(bytecode_cache_tests).step);
    }

    const dispatch_contract_step = b.step("test-ng-dispatch", "Run QuickJS-NG location-dispatch contract");
    if (backend == .quickjs_ng) {
        const run_dispatch_contract = b.addSystemCommand(&.{"sh"});
        run_dispatch_contract.addFileArg(b.path("tests/quickjs_ng_dispatch_contract.sh"));
        run_dispatch_contract.addDirectoryArg(qjs_root.?);
        dispatch_contract_step.dependOn(&run_dispatch_contract.step);
    } else {
        const unsupported = b.addSystemCommand(&.{ "sh", "-c", "printf '%s\\n' 'test-ng-dispatch requires -Dbackend=quickjs_ng' >&2; exit 1" });
        dispatch_contract_step.dependOn(&unsupported.step);
    }

    // An instrumented test-only archive keeps rejection observation out of the distributed ABI while evaluating cases through the normal C API.
    const conformance_module = b.createModule(.{
        .root_source_file = b.path("src/test262_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    conformance_module.addOptions("build_options", build_options);
    conformance_module.addImport("zev", zev);
    conformance_module.addImport("js_event_loop", js_event_loop);
    conformance_module.addImport("inspector", inspector);
    conformance_module.addImport("inspector_transport", inspector_transport);
    conformance_module.addImport("bytecode_cache", bytecode_cache);
    if (qjs_mod) |qjs| conformance_module.addImport("qjs", qjs);
    addPlatformCompatSources(b, conformance_module);
    addBackendSources(b, conformance_module, backend, quickjs_gc_stress, os, qjs_root, inspector_enabled, heap_snapshot, asan, spike_escargot_install, spike_hermes_install, spike_libstdcxx, spike_icu_lib_dir);
    const conformance_library = b.addLibrary(.{
        .name = "js_bay_test262",
        .root_module = conformance_module,
        .linkage = .static,
    });
    conformance_library.bundle_compiler_rt = true;
    const install_conformance = b.addInstallArtifact(conformance_library, .{});
    b.step("test262-host", "Build the isolated Test262 C-ABI host archive").dependOn(&install_conformance.step);

    // --- Formatting steps ---
    // Follows the official Zig repository conventions:
    // - `zig build fmt`: in-place formatting of project source files.
    // - `zig build test-fmt` / `check-fmt`: verification mode for CI and pre-commit checks.
    const fmt_paths: []const std.Build.LazyPath = &.{
        b.path("src"),
        b.path("tests"),
        b.path("bench"),
        b.path("examples"),
        b.path("libs"),
        b.path("tools"),
        b.path("build.zig"),
        b.path("build.zig.zon"),
    };

    const fmt_step = b.step("fmt", "Run zig fmt on project source files");
    const fmt = b.addFmt(.{
        .paths = fmt_paths,
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const test_fmt_step = b.step("test-fmt", "Check formatting of project source files");
    const test_fmt = b.addFmt(.{
        .paths = fmt_paths,
        .check = true,
    });
    test_fmt_step.dependOn(&test_fmt.step);

    const check_fmt_step = b.step("check-fmt", "Alias for test-fmt");
    check_fmt_step.dependOn(&test_fmt.step);

    // Cross-platform packaging consumes only the library. Benchmark/demo executables target the developer host and must not be linked as iOS or Android binaries as part of an XCFramework/JNI build.
    if (library_only) return;

    // --- Benchmark executable ---
    // Separate binary that imports js_bay and measures eval, native-call, promise, and typed-array throughput.
    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_module.addImport("js_bay_tools", internal_tools_module);
    bench_module.addOptions("build_options", build_options);
    bench_module.addImport("zev", zev);
    bench_module.addImport("js_event_loop", js_event_loop);
    bench_module.addImport("inspector", inspector);
    bench_module.addImport("inspector_transport", inspector_transport);
    bench_module.addImport("bytecode_cache", bytecode_cache);
    if (qjs_mod) |qjs| bench_module.addImport("qjs", qjs);

    addPlatformCompatSources(b, bench_module);
    addBackendSources(b, bench_module, backend, quickjs_gc_stress, os, qjs_root, inspector_enabled, heap_snapshot, asan, spike_escargot_install, spike_hermes_install, spike_libstdcxx, spike_icu_lib_dir);

    const bench_exe = b.addExecutable(.{
        .name = b.fmt("bench-{s}", .{@tagName(backend)}),
        .root_module = bench_module,
    });

    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    forwardRunArgs(b, run_bench);
    const bench_step = b.step("bench", "Run js-bay benchmarks");
    bench_step.dependOn(&run_bench.step);

    // --- Inspector demo ---
    // Standalone runnable that starts an engine + CDP inspector and drives the event loop. Used for manual Chrome DevTools testing and as the target of `tests/inspector/e2e.cjs`.
    const demo_module = b.createModule(.{
        .root_source_file = b.path("examples/inspector_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_module.addImport("js_bay_tools", internal_tools_module);
    demo_module.addOptions("build_options", build_options);
    demo_module.addImport("zev", zev);
    demo_module.addImport("js_event_loop", js_event_loop);
    demo_module.addImport("inspector", inspector);
    demo_module.addImport("inspector_transport", inspector_transport);
    demo_module.addImport("bytecode_cache", bytecode_cache);
    if (qjs_mod) |qjs| demo_module.addImport("qjs", qjs);

    addPlatformCompatSources(b, demo_module);
    addBackendSources(b, demo_module, backend, quickjs_gc_stress, os, qjs_root, inspector_enabled, heap_snapshot, asan, spike_escargot_install, spike_hermes_install, spike_libstdcxx, spike_icu_lib_dir);

    const demo_exe = b.addExecutable(.{
        .name = b.fmt("inspector-demo-{s}", .{@tagName(backend)}),
        .root_module = demo_module,
    });

    b.installArtifact(demo_exe);

    const run_demo = b.addRunArtifact(demo_exe);
    forwardRunArgs(b, run_demo);
    const demo_step = b.step("inspector-demo", "Run CDP inspector demo harness");
    demo_step.dependOn(&run_demo.step);

    // --- JSC Safari-attachable inspector demo ---
    // Uses JavaScriptCore's built-in WebKit Inspector. Only meaningful on JSC + Darwin; under QJS or non-Apple targets we skip the entire step so `zig build` stays green.
    if (backend == .jsc and (os == .macos or os == .ios)) {
        const safari_module = b.createModule(.{
            .root_source_file = b.path("examples/jsc_safari_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        safari_module.addImport("js_bay_tools", internal_tools_module);
        safari_module.addOptions("build_options", build_options);
        safari_module.addImport("zev", zev);
        safari_module.addImport("js_event_loop", js_event_loop);
        safari_module.addImport("inspector", inspector);
        safari_module.addImport("inspector_transport", inspector_transport);
        safari_module.addImport("bytecode_cache", bytecode_cache);
        safari_module.linkFramework("JavaScriptCore", .{});
        safari_module.linkFramework("Foundation", .{});
        safari_module.addCSourceFile(.{
            .file = b.path("src/backend/jsc/module_loader.m"),
            .flags = &.{ "-fobjc-arc", "-Wno-unused-function" },
        });
        addPlatformCompatSources(b, safari_module);

        const safari_demo = b.addExecutable(.{
            .name = "jsc-safari-demo",
            .root_module = safari_module,
        });
        b.installArtifact(safari_demo);
        const run_safari = b.addRunArtifact(safari_demo);
        forwardRunArgs(b, run_safari);
        const safari_step = b.step("safari-demo", "Run JSC Safari-attachable inspector demo (macOS/iOS only)");
        safari_step.dependOn(&run_safari.step);
    }
}

fn forwardRunArgs(_: *std.Build, run: *std.Build.Step.Run) void {
    run.addPassthruArgs();
}

fn prepareIosStdlib(b: *std.Build, tool: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addArg("prepare-ios-stdlib");
    run.addFileArg(std.Build.LazyPath.zig_lib.path(b, "std/process.zig"));
    run.addFileInput(std.Build.LazyPath.zig_lib.path(b, "std/std.zig"));
    run.addFileInput(std.Build.LazyPath.zig_lib.path(b, "std/Io/Threaded.zig"));
    return run.addOutputDirectoryArg("zig-ios-lib");
}

/// Copy the pinned QuickJS-NG submodule into the build cache and apply patches.
fn preparePatchedQuickJsNg(b: *std.Build, tool: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addArg("patch-quickjs-ng");
    run.addDirectoryArg(b.path(quickjs_ng_root));
    const out = run.addOutputDirectoryArg("patched-quickjs-ng");
    run.addFileArg(b.path("vendor/quickjs-ng-debugger.patch"));
    run.addFileArg(b.path("vendor/quickjs-ng-debugger-pause.patch"));
    run.addFileArg(b.path("vendor/quickjs-ng-dataview-native.patch"));
    run.addFileArg(b.path("vendor/quickjs-ng-optional-inspector.patch"));
    run.addFileArg(b.path("vendor/quickjs-ng-heap-labels.patch"));
    run.addFileArg(b.path("vendor/quickjs-ng-break-locations.patch"));
    run.addFileArg(b.path("vendor/quickjs-ng-script-tags.patch"));
    run.addFileArg(b.path("vendor/quickjs-ng-inspector-off.patch"));
    return out;
}

/// Copy the pinned QuickJS submodule into the build cache and apply patches.
fn preparePatchedQuickJs(b: *std.Build, tool: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addRunArtifact(tool);
    run.addArg("patch-quickjs");
    run.addDirectoryArg(b.path(quickjs_root));
    const out = run.addOutputDirectoryArg("patched-quickjs");
    run.addFileArg(b.path("vendor/quickjs-finalizer.patch"));
    run.addFileArg(b.path("vendor/quickjs-heap.patch"));
    run.addFileArg(b.path("vendor/quickjs-async-stack.patch"));
    run.addFileArg(b.path("vendor/quickjs-ubsan.patch"));
    run.addFileArg(b.path("vendor/quickjs-array-identity.patch"));
    run.addFileArg(b.path("vendor/quickjs-dataview-native.patch"));
    run.addFileArg(b.path("vendor/quickjs-heap-labels.patch"));
    run.addFileArg(b.path("vendor/quickjs-promise-then.patch"));
    run.addFileArg(b.path("vendor/quickjs-inspector-off.patch"));
    run.addFileArg(b.path("vendor/quickjs-transfer-neuter.patch"));
    return out;
}

/// Adds the selected engine's C sources / system libraries to `m`.
fn addBackendSources(
    b: *std.Build,
    m: *std.Build.Module,
    backend: Backend,
    quickjs_gc_stress: bool,
    os: std.Target.Os.Tag,
    qjs_root: ?std.Build.LazyPath,
    inspector_enabled: bool,
    heap_snapshot: bool,
    asan: bool,
    escargot_install: []const u8,
    hermes_install: []const u8,
    libstdcxx: ?[]const u8,
    icu_lib_dir: ?[]const u8,
) void {
    m.addCMacro("JS_BAY_INSPECTOR", if (inspector_enabled) "1" else "0");
    m.addCMacro("JS_BAY_HEAP_SNAPSHOT", if (heap_snapshot) "1" else "0");
    switch (backend) {
        .quickjs_ng => addQuickJsNgSources(b, m, quickjs_gc_stress, qjs_root.?, asan),
        .quickjs => addQuickJsSources(b, m, quickjs_gc_stress, qjs_root.?, asan),
        .jsc => {
            if (os == .macos or os == .ios) {
                m.linkFramework("JavaScriptCore", .{});
                m.linkFramework("Foundation", .{});
                m.addCSourceFile(.{
                    .file = b.path("src/backend/jsc/module_loader.m"),
                    .flags = &.{
                        "-fobjc-arc",
                        "-Wno-unused-function",
                    },
                });
            } else {
                m.linkSystemLibrary("JavaScriptCore", .{});
            }
        },
        .escargot => addEscargotSources(b, m, escargot_install, libstdcxx.?),
        .hermes => addHermesSources(b, m, hermes_install, libstdcxx.?, icu_lib_dir.?),
    }
}

fn addEscargotSources(b: *std.Build, m: *std.Build.Module, install_prefix: []const u8, libstdcxx: []const u8) void {
    // EscargotPublic C bridge + libescargot (g++/local-exec TLS).
    // Zig's linkSystemLibrary("stdc++") is special-cased to libc++ — link libstdc++.a by path.
    const install = b.path(install_prefix);
    m.addIncludePath(install.path(b, "include"));
    m.addIncludePath(b.path("src/backend/escargot"));
    m.addObjectFile(install.path(b, "lib/escargot_bridge.o"));
    const libs = [_][]const u8{
        "lib/libescargot.a",
        "lib/libgc-lib.a",
        "lib/liblibbf.a",
        "lib/liblibsimdutf.a",
        "lib/libruntime-icu-binder-static.a",
    };
    for (libs) |rel| {
        m.addObjectFile(install.path(b, rel));
    }
    m.link_libcpp = false;
    m.addObjectFile(.{ .cwd_relative = libstdcxx });
    m.linkSystemLibrary("pthread", .{});
    m.linkSystemLibrary("dl", .{});
    m.linkSystemLibrary("m", .{});
    m.linkSystemLibrary("rt", .{});
    m.linkSystemLibrary("gcc_s", .{});
}

fn addHermesSources(b: *std.Build, m: *std.Build.Module, install_prefix: []const u8, libstdcxx: []const u8, icu_lib_dir: []const u8) void {
    // Hermes/JSI C bridge as a shared lib (libhermes_bridge.so), not a .o into the Zig
    // binary. HostFunction `throw jsi::JSError` must unwind with GCC libstdc++/libgcc_s
    // that hermesvm.so uses; Zig's libunwind + a static/second libstdc++ ABRTs across DSO.
    _ = libstdcxx; // required by outer guard / Escargot parity of env
    const install = b.path(install_prefix);
    m.addIncludePath(b.path("src/backend/hermes"));
    m.addIncludePath(install.path(b, "include"));
    m.addLibraryPath(install.path(b, "lib"));
    m.addLibraryPath(.{ .cwd_relative = icu_lib_dir });
    m.addRPath(install.path(b, "lib"));
    m.addRPath(.{ .cwd_relative = icu_lib_dir });
    m.linkSystemLibrary("hermes_bridge", .{});
    m.linkSystemLibrary("hermesvm", .{});
    m.linkSystemLibrary("jsi", .{});
    m.linkSystemLibrary("icuuc", .{});
    m.linkSystemLibrary("icui18n", .{});
    m.linkSystemLibrary("icudata", .{});
    m.link_libcpp = false;
    m.linkSystemLibrary("pthread", .{});
    m.linkSystemLibrary("dl", .{});
    m.linkSystemLibrary("m", .{});
    m.linkSystemLibrary("gcc_s", .{});
}

fn addQuickJsNgSources(b: *std.Build, m: *std.Build.Module, gc_stress: bool, qjs_root: std.Build.LazyPath, asan: bool) void {
    const sources = [_][]const u8{
        "quickjs.c",
        "libregexp.c",
        "libunicode.c",
        "dtoa.c",
        "src/backend/quickjs_common/qjs_wrapper.c",
        "src/backend/quickjs_ng/qjs_wrapper_ng.c",
    };
    addQuickJsCSources(b, m, qjs_root, &sources, "2024-02-14", gc_stress, asan);
}

fn addQuickJsSources(b: *std.Build, m: *std.Build.Module, gc_stress: bool, qjs_root: std.Build.LazyPath, asan: bool) void {
    const sources = [_][]const u8{
        "quickjs.c",
        "libregexp.c",
        "libunicode.c",
        "dtoa.c",
        "cutils.c",
        "src/backend/quickjs_common/qjs_wrapper.c",
        "src/backend/quickjs/qjs_wrapper_quickjs.c",
    };
    addQuickJsCSources(b, m, qjs_root, &sources, "2026-06-04", gc_stress, asan);
    m.addIncludePath(b.path("src/backend/quickjs"));
}

fn addQuickJsCSources(
    b: *std.Build,
    m: *std.Build.Module,
    qjs_root: std.Build.LazyPath,
    sources: []const []const u8,
    version: []const u8,
    gc_stress: bool,
    asan: bool,
) void {
    // Engine source lists and patch scripts stay separate. Only build flags and the narrow, identical C ABI normalization wrapper are shared.
    const c_opt: []const u8 = switch (m.optimize orelse .debug) {
        .debug => "-O0",
        .safe => "-O2",
        .fast, .small => "-O3",
    };
    // Harsh-father ASan: instrument QuickJS C + wrappers; final consumer must link -fsanitize=address.
    const c_flags: []const []const u8 = blk: {
        if (asan and gc_stress)
            break :blk &.{ b.fmt("-DCONFIG_VERSION=\"{s}\"", .{version}), "-DFORCE_GC_AT_MALLOC=1", "-fwrapv", "-w", c_opt, "-fsanitize=address", "-fno-omit-frame-pointer" };
        if (asan)
            break :blk &.{ b.fmt("-DCONFIG_VERSION=\"{s}\"", .{version}), "-fwrapv", "-w", c_opt, "-fsanitize=address", "-fno-omit-frame-pointer" };
        if (gc_stress)
            break :blk &.{ b.fmt("-DCONFIG_VERSION=\"{s}\"", .{version}), "-DFORCE_GC_AT_MALLOC=1", "-fwrapv", "-w", c_opt };
        break :blk &.{ b.fmt("-DCONFIG_VERSION=\"{s}\"", .{version}), "-fwrapv", "-w", c_opt };
    };
    for (sources) |src| {
        m.addCSourceFile(.{
            .file = if (std.mem.startsWith(u8, src, "src/")) b.path(src) else qjs_root.path(b, src),
            .flags = c_flags,
        });
    }
    m.addIncludePath(qjs_root);
}

fn addPlatformCompatSources(b: *std.Build, m: *std.Build.Module) void {
    if (m.resolved_target.?.result.abi.isAndroid()) {
        m.addCSourceFile(.{ .file = b.path("src/platform/android_compat.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror", "-O2" } });
    }
    const abi = m.resolved_target.?.result.abi;
    if (abi == .ohos or abi == .ohoseabi) {
        m.addCSourceFile(.{ .file = b.path("src/platform/ohos_compat.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror", "-O2" } });
    }
}

/// Cache identity follows the pinned engine, patches, target and compiler options.
fn bytecodeFingerprint(b: *std.Build, target: std.Target, backend: Backend, optimize: std.builtin.OptimizeMode, gc_stress: bool, inspector_enabled: bool, heap_snapshot: bool) []const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("js-bay-bytecode-cache-v1\x00");
    hash.update(@embedFile("build.zig.zon"));
    hash.update(@embedFile("build.zig"));
    hash.update(@embedFile("tools/src/repository.zig"));
    hash.update(@embedFile("src/backend/quickjs_common/qjs_wrapper.c"));
    hash.update(@embedFile("src/script/cjs_wrapper.zig"));
    hash.update(@embedFile("src/script/typed_eval.zig"));
    switch (backend) {
        .quickjs => {
            hashQuickJsSources(&hash, "vendor/quickjs", false);
            hash.update(@embedFile("vendor/quickjs-finalizer.patch"));
            hash.update(@embedFile("vendor/quickjs-heap.patch"));
            hash.update(@embedFile("vendor/quickjs-async-stack.patch"));
            hash.update(@embedFile("vendor/quickjs-ubsan.patch"));
            hash.update(@embedFile("vendor/quickjs-array-identity.patch"));
            hash.update(@embedFile("vendor/quickjs-dataview-native.patch"));
            hash.update(@embedFile("vendor/quickjs-heap-labels.patch"));
            hash.update(@embedFile("vendor/quickjs-promise-then.patch"));
            hash.update(@embedFile("vendor/quickjs-inspector-off.patch"));
            hash.update(@embedFile("vendor/quickjs-transfer-neuter.patch"));
            hash.update(@embedFile("src/backend/quickjs/quickjs_shim.h"));
            hash.update(@embedFile("src/backend/quickjs/qjs_wrapper_quickjs.c"));
            hash.update(@embedFile("src/backend/quickjs/bytecode.zig"));
        },
        .quickjs_ng => {
            hashQuickJsSources(&hash, "vendor/quickjs-ng", true);
            hash.update(@embedFile("vendor/quickjs-ng-debugger.patch"));
            hash.update(@embedFile("vendor/quickjs-ng-debugger-pause.patch"));
            hash.update(@embedFile("vendor/quickjs-ng-dataview-native.patch"));
            hash.update(@embedFile("vendor/quickjs-ng-optional-inspector.patch"));
            hash.update(@embedFile("vendor/quickjs-ng-heap-labels.patch"));
            hash.update(@embedFile("vendor/quickjs-ng-break-locations.patch"));
            hash.update(@embedFile("vendor/quickjs-ng-script-tags.patch"));
            hash.update(@embedFile("vendor/quickjs-ng-inspector-off.patch"));
            hash.update(@embedFile("src/backend/quickjs_ng/qjs_wrapper_ng.c"));
            hash.update(@embedFile("src/backend/quickjs_ng/bytecode.zig"));
        },
        .jsc => {},
        .escargot, .hermes => {},
    }
    const triple = target.zigTriple(b.allocator) catch @panic("out of memory");
    hash.update(b.fmt("\x00{s}\x00{s}\x00{s}\x00{s}\x00{}\x00{}\x00{}", .{
        @tagName(backend), triple, target.cpu.model.name, @tagName(optimize), gc_stress, inspector_enabled, heap_snapshot,
    }));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return b.allocator.dupe(u8, &encoded) catch @panic("out of memory");
}

fn hashQuickJsSources(hash: *std.crypto.hash.sha2.Sha256, comptime root: []const u8, comptime ng: bool) void {
    inline for (.{ "quickjs.h", "quickjs.c", "quickjs-opcode.h", "quickjs-atom.h", "libregexp.c", "libregexp.h", "libregexp-opcode.h", "libunicode.c", "libunicode.h", "libunicode-table.h", "dtoa.c", "dtoa.h", "cutils.h", "list.h" }) |file| {
        hash.update(@embedFile(root ++ "/" ++ file));
    }
    if (ng) {
        inline for (.{ "quickjs-c-atomics.h", "builtin-array-fromasync.h", "builtin-iterator-zip.h", "builtin-iterator-zip-keyed.h" }) |file| {
            hash.update(@embedFile(root ++ "/" ++ file));
        }
    } else {
        hash.update(@embedFile(root ++ "/cutils.c"));
    }
}

fn androidLibTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => @panic("unsupported Android architecture"),
    };
}

fn ohosLibTriple(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "aarch64-linux-ohos",
        .x86_64 => "x86_64-linux-ohos",
        .arm => "arm-linux-ohos",
        else => @panic("unsupported OpenHarmony architecture"),
    };
}
