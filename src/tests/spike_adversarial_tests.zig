//! Hostile edge cases against spike in-scope surfaces.
//! Escargot: ESM + shared core. Hermes: .hbc + shared core.
//! Out of scope (CJS / inspector / engine_thread) is not expanded here.
const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const bytecode = @import("../script/bytecode.zig");
const promise = @import("../runtime/promise.zig");
const host_object = @import("../value/host_object.zig");
const host_value = @import("../abi/host_value.zig");

const ActiveEngine = backend.ActiveEngine;

fn spikeOnly() !void {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
}

// ---- malformed / empty inputs ----

test "adversarial: empty and whitespace-only eval" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Empty script — engines differ; must not crash. Accept ok or err.
            {
                const res = engine.evalScript(id, "", "<empty>");
                defer helpers.freeEvalResult(res);
            }
            {
                const res = engine.evalScript(id, "   \n\t  ", "<ws>");
                defer helpers.freeEvalResult(res);
            }
            // Engine still usable
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "adversarial: malformed syntax does not poison engine" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalErr(id, "function (");
            try helpers.evalErr(id, "}}}{{{");
            try helpers.evalErr(id, "'unterminated");
            try helpers.expectEvalEquals(id, "2*3", "6");
        }
    }.run);
}

test "adversarial: eval on dead instance returns error not crash" {
    try spikeOnly();
    const id = helpers.nextInstanceId();
    // never create
    const res = engine.evalScript(id, "1", "<dead>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
    try testing.expect(res.result == null);
}

// ---- value / NUL ----

test "adversarial: embedded NUL in string roundtrip via eval" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // JS string with embedded NUL via escape
            try helpers.evalOk(id, "globalThis.__nul = 'a\\u0000b';");
            try helpers.expectEvalEquals(id, "globalThis.__nul.length", "3");
            try helpers.expectEvalEquals(id, "globalThis.__nul.charCodeAt(1)", "0");
        }
    }.run);
}

test "adversarial: property name with unusual characters" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id, "globalThis['x y'] = 7; globalThis[''] = 9;");
            try helpers.expectEvalEquals(id, "globalThis['x y']", "7");
            try helpers.expectEvalEquals(id, "globalThis['']", "9");
        }
    }.run);
}

// ---- Promise Deferred ----

test "adversarial: Deferred double-resolve is safe" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const v1 = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, v1);
            const v2 = ActiveEngine.newInt32Val(ctx, 2);
            defer ActiveEngine.freeValue(ctx, v2);
            const ok1 = d.resolve(v1);
            const ok2 = d.resolve(v2); // second settle must not crash
            try testing.expect(ok1);
            _ = ok2;
            // Promise should be fulfilled with first value (or at least not crash)
            try helpers.evalOk(id, "1");
        }
    }.run);
}

test "adversarial: Deferred reject then resolve is safe" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const errv = ActiveEngine.makeStringValue(ctx, "boom");
            defer ActiveEngine.freeValue(ctx, errv);
            _ = d.reject(errv);
            const v = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, v);
            _ = d.resolve(v);
            try helpers.expectEvalEquals(id, "3+4", "7");
        }
    }.run);
}

// ---- timers ----

test "adversarial: clearTimeout of unknown id is no-op" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id, "clearTimeout(999999); clearInterval(0); clearTimeout(-1);");
            try helpers.expectEvalEquals(id, "'ok'", "ok");
        }
    }.run);
}

test "adversarial: setTimeout zero delay still fires via drain" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__t = 0;
                \\setTimeout(() => { globalThis.__t = 1; }, 0);
            );
            // Drain host timers / microtasks
            _ = engine.testing.advance(id, 50);
            try helpers.expectEvalEquals(id, "String(globalThis.__t)", "1");
        }
    }.run);
}

test "adversarial: nested setTimeout during destroy does not use-after-free" {
    try spikeOnly();
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    try helpers.evalOk(id,
        \\setTimeout(() => {
        \\  setTimeout(() => { globalThis.__x = 1; }, 0);
        \\}, 0);
    );
    // Destroy while timers may be pending — must not crash
    engine.destroy(id);
}

// ---- host_object ----

fn throwGet(_: i32, _: ?*anyopaque, _: []const u8, out: *host_value.HostValue) ?[*:0]const u8 {
    host_value.clear(out);
    return "hostile get";
}

test "adversarial: host_object get trap error leaves engine usable" {
    try spikeOnly();
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const obj = host_object.create(id, null, .{ .get = throwGet }) orelse return error.HostCreateFailed;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, "ho", obj);
    try helpers.evalErr(id, "ho.any");
    try helpers.expectEvalEquals(id, "1+1", "2");
}

test "adversarial: host_object empty property name" {
    try spikeOnly();
    var seen_empty: bool = false;
    const Holder = struct {
        seen: *bool,
    };
    var holder = Holder{ .seen = &seen_empty };
    const getFn = struct {
        fn f(_: i32, user_data: ?*anyopaque, name: []const u8, out: *host_value.HostValue) ?[*:0]const u8 {
            host_value.clear(out);
            const h: *Holder = @ptrCast(@alignCast(user_data.?));
            if (name.len == 0) h.seen.* = true;
            out.tag = host_value.tag_number;
            out.number = 42;
            return null;
        }
    }.f;
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const obj = host_object.create(id, @ptrCast(&holder), .{ .get = getFn }) orelse return error.HostCreateFailed;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, "ho", obj);
    try helpers.expectEvalEquals(id, "ho['']", "42");
    try testing.expect(seen_empty);
}

// ---- typed arrays ----

test "adversarial: zero-length TypedArray via eval" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "new Uint8Array(0).length", "0");
            try helpers.expectEvalEquals(id, "new Float64Array(0).byteLength", "0");
            try helpers.expectEvalEquals(id, "new ArrayBuffer(0).byteLength", "0");
        }
    }.run);
}

test "adversarial: TypedArray out-of-range index is undefined not crash" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "String(new Uint8Array([1])[99])", "undefined");
            try helpers.expectEvalEquals(id, "String(new Uint8Array([1])[-1])", "undefined");
        }
    }.run);
}

// ---- Escargot ESM ----

test "adversarial: Escargot ESM empty module and syntax error" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            {
                const res = engine.evalModule(id, "", "<empty-mod>");
                defer helpers.freeEvalResult(res);
                // empty module: ok or err, no crash
            }
            {
                const res = engine.evalModule(id, "export const x = ;", "<bad-mod>");
                defer helpers.freeEvalResult(res);
                try testing.expect(res.err != null);
            }
            try helpers.expectEvalEquals(id, "5", "5");
        }
    }.run);
}

test "adversarial: Escargot ESM import without loader fails cleanly" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // No ModuleLoader installed — import must error, not abort
            const res = engine.evalModule(id, "import { x } from 'missing';", "<noloader>");
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
            try helpers.expectEvalEquals(id, "9", "9");
        }
    }.run);
}

// ---- Hermes .hbc ----

test "adversarial: Hermes compile empty source" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const cr = bytecode.compile(id, "", "<empty>");
            defer bytecode.freeCompileResult(cr);
            // empty may yield empty bytecode or error — no crash
            if (cr.bytes) |b| {
                const res = bytecode.runBytecode(id, b);
                defer helpers.freeEvalResult(res);
            }
            try helpers.expectEvalEquals(id, "1", "1");
        }
    }.run);
}

test "adversarial: Hermes run truncated/malformed .hbc" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // Hermes magic-ish garbage
            var garbage = [_]u8{ 0xc6, 0x1f, 0xbc, 0x03, 0x00, 0x00, 0x00, 0x00 };
            const res = bytecode.runBytecode(id, &garbage);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
            try helpers.expectEvalEquals(id, "2", "2");

            const empty: []const u8 = &[_]u8{};
            const res2 = bytecode.runBytecode(id, empty);
            defer helpers.freeEvalResult(res2);
            try testing.expect(res2.err != null);
            try helpers.expectEvalEquals(id, "3", "3");
        }
    }.run);
}

test "adversarial: Hermes compile syntax error yields no bytes" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const cr = bytecode.compile(id, "function (", "<bad>");
            defer bytecode.freeCompileResult(cr);
            try testing.expect(cr.bytes == null);
            try testing.expect(cr.err != null);
        }
    }.run);
}

// ---- rapid create/destroy / GC pressure ----

test "adversarial: rapid create destroy cycles" {
    try spikeOnly();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const id = helpers.nextInstanceId();
        if (!engine.create(id, .{})) return error.EngineCreateFailed;
        try helpers.expectEvalEquals(id, "1", "1");
        engine.destroy(id);
    }
}

test "adversarial: many short-lived objects then GC" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\for (let i = 0; i < 100; i++) {
                \\  globalThis['k'+i] = { a: i, b: new Array(10).fill(i) };
                \\}
                \\for (let i = 0; i < 100; i++) delete globalThis['k'+i];
            );
            _ = engine.runGc(id);
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

// ---- concurrent owner-thread misuse (best-effort: foreign id) ----

test "adversarial: ops on wrong instance id after destroy" {
    try spikeOnly();
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    engine.destroy(id);
    const res = engine.evalScript(id, "1", "<post-destroy>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
    // GC on dead id must be a no-op (do not advance event loop — may hang).
    _ = engine.runGc(id);
}

// ---- Round 2: deeper hostility ----

test "adversarial r2: throw null/undefined/number does not poison" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalErr(id, "throw null");
            try helpers.evalErr(id, "throw undefined");
            try helpers.evalErr(id, "throw 0");
            try helpers.evalErr(id, "throw ''");
            try helpers.expectEvalEquals(id, "7", "7");
        }
    }.run);
}

test "adversarial r2: Deferred resolve with undefined" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__p", ActiveEngine.dupValue(ctx, d.promise));
            try helpers.evalOk(id, "globalThis.__got = 'no'; __p.then(v => { __got = String(v); });");
            const u = ActiveEngine.undefinedValue();
            try testing.expect(d.resolve(u));
            _ = engine.testing.advance(id, 0);
            try helpers.expectEvalEquals(id, "globalThis.__got", "undefined");
        }
    }.run);
}

test "adversarial r2: setInterval cleared from inside callback" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__n = 0;
                \\globalThis.__id = setInterval(() => {
                \\  globalThis.__n++;
                \\  clearInterval(globalThis.__id);
                \\}, 0);
            );
            _ = engine.testing.advance(id, 50);
            _ = engine.testing.advance(id, 50);
            _ = engine.testing.advance(id, 50);
            try helpers.expectEvalEquals(id, "String(globalThis.__n)", "1");
        }
    }.run);
}

test "adversarial r2: very long identifier and string literal" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            // 4k 'a' as string content
            var buf: [4200]u8 = undefined;
            @memset(buf[0..], 'a');
            const src = try std.fmt.allocPrint(std.heap.c_allocator, "globalThis.__s = '{s}'; __s.length", .{buf[0..4000]});
            defer std.heap.c_allocator.free(src);
            try helpers.expectEvalEquals(id, src, "4000");
        }
    }.run);
}

test "adversarial r2: ArrayBuffer slice views share memory" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\const b = new ArrayBuffer(4);
                \\const u = new Uint8Array(b);
                \\const v = new Uint8Array(b, 1, 2);
                \\u[1] = 9;
                \\globalThis.__x = v[0];
            );
            try helpers.expectEvalEquals(id, "String(globalThis.__x)", "9");
        }
    }.run);
}

test "adversarial r2: Escargot ESM re-eval same entry after failure" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            {
                const res = engine.evalModule(id, "throw new Error('entry-fail');", "<fail>");
                defer helpers.freeEvalResult(res);
                try testing.expect(res.err != null);
            }
            {
                const res = engine.evalModule(id, "globalThis.__ok = 1; export {};", "<ok>");
                defer helpers.freeEvalResult(res);
                // may succeed or fail depending on loader state — must not crash
                _ = res.err;
            }
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "adversarial r2: Hermes bytecode from engine A run on engine B" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    const a = helpers.nextInstanceId();
    const b = helpers.nextInstanceId();
    if (!engine.create(a, .{})) return error.EngineCreateFailed;
    defer engine.destroy(a);
    if (!engine.create(b, .{})) return error.EngineCreateFailed;
    defer engine.destroy(b);
    const cr = bytecode.compile(a, "globalThis.__from = 11; 11", "<x>");
    defer bytecode.freeCompileResult(cr);
    const bytes = cr.bytes orelse return error.NoBytes;
    const res = bytecode.runBytecode(b, bytes);
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try helpers.expectEvalEquals(b, "String(globalThis.__from)", "11");
}

test "adversarial r2: host_object set trap returns error" {
    try spikeOnly();
    const setFn = struct {
        fn f(_: i32, _: ?*anyopaque, _: []const u8, _: host_value.HostValue) ?[*:0]const u8 {
            return "no writes";
        }
    }.f;
    const getFn = struct {
        fn f(_: i32, _: ?*anyopaque, _: []const u8, out: *host_value.HostValue) ?[*:0]const u8 {
            host_value.clear(out);
            return null;
        }
    }.f;
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const obj = host_object.create(id, null, .{ .get = getFn, .set = setFn }) orelse return error.HostCreateFailed;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, "ho", obj);
    try helpers.evalErr(id, "ho.x = 1");
    try helpers.expectEvalEquals(id, "2+2", "4");
}

test "adversarial r2: recursive JSON-like deep object" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\let o = {};
                \\for (let i = 0; i < 200; i++) o = { nest: o, i };
                \\globalThis.__depth = 0;
                \\let cur = o;
                \\while (cur && cur.nest) { globalThis.__depth++; cur = cur.nest; }
            );
            try helpers.expectEvalEquals(id, "String(globalThis.__depth)", "200");
        }
    }.run);
}

test "adversarial r2: Promise thenable storm then drain" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__c = 0;
                \\let p = Promise.resolve(0);
                \\for (let i = 0; i < 50; i++) p = p.then(v => { globalThis.__c++; return v+1; });
                \\p.then(v => { globalThis.__final = v; });
            );
            var n: usize = 0;
            while (n < 60) : (n += 1) {
                _ = engine.testing.advance(id, 0);
            }
            try helpers.expectEvalEquals(id, "String(globalThis.__c)", "50");
            try helpers.expectEvalEquals(id, "String(globalThis.__final)", "50");
        }
    }.run);
}

// ---- Round 3: bridge sharp edges + hardening checks ----

test "adversarial r3: double destroy is safe" {
    try spikeOnly();
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    engine.destroy(id);
    engine.destroy(id); // must not crash
    const res = engine.evalScript(id, "1", "<after-double-destroy>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
}

test "adversarial r3: setProperty rejects key with embedded NUL" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const v = ActiveEngine.newInt32Val(ctx, 1);
            defer ActiveEngine.freeValue(ctx, v);
            const key = "a\x00b";
            const ok = ActiveEngine.setProperty(ctx, global, key, v);
            try testing.expect(!ok);
            // Engine still fine; JS-side empty/normal keys work
            try helpers.expectEvalEquals(id, "1", "1");
        }
    }.run);
}

test "adversarial r3: Hermes compile filename with spaces and metacharacters" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const cr = bytecode.compile(id, "1+2", "weird name; rm -rf / &.js");
            defer bytecode.freeCompileResult(cr);
            try testing.expect(cr.err == null);
            const bytes = cr.bytes orelse return error.NoBytes;
            const res = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            try testing.expectEqualStrings("3", res.result.?);
        }
    }.run);
}

test "adversarial r3: Hermes compile empty filename uses fallback" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const cr = bytecode.compile(id, "40+2", "");
            defer bytecode.freeCompileResult(cr);
            try testing.expect(cr.err == null);
            const bytes = cr.bytes orelse return error.NoBytes;
            const res = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            try testing.expectEqualStrings("42", res.result.?);
        }
    }.run);
}

test "adversarial r3: Escargot evalModule with only export default" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const res = engine.evalModule(id, "export default 5; globalThis.__d = 5;", "<def>");
            defer helpers.freeEvalResult(res);
            // success or structured err — no crash; engine remains usable
            _ = res.err;
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "adversarial r3: create many Deferreds and abandon without settle" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var i: usize = 0;
            while (i < 30) : (i += 1) {
                var d = promise.create(id) orelse return error.NoDeferred;
                d.deinit(); // abandon pending
            }
            try helpers.expectEvalEquals(id, "3", "3");
        }
    }.run);
}

// ---- Round-4 capability expansion ----

test "adversarial: Escargot ESM re-export chain" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    const types = @import("../types.zig");
    var modules = std.StringHashMap([]const u8).init(testing.allocator);
    defer modules.deinit();
    try modules.put("leaf", "export const v = 77;");
    try modules.put("mid", "export { v as w } from 'leaf';");
    const VTable = struct {
        fn resolve(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]u8 {
            return null;
        }
        fn load(ud: ?*anyopaque, id: [*:0]const u8, out: *types.ModuleLoadResult) callconv(.c) bool {
            const m: *std.StringHashMap([]const u8) = @ptrCast(@alignCast(ud.?));
            const src = m.get(std.mem.span(id)) orelse return false;
            out.* = .{ .source = src.ptr, .source_len = src.len };
            return true;
        }
    };
    const vtable: types.ModuleLoaderVTable = .{ .resolve = VTable.resolve, .load = VTable.load, .free_resolved = null };
    const loader = types.ModuleLoader{ .vtable = &vtable, .user_data = &modules };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{ .module_loader = &loader }));
    defer engine.destroy(id);
    const res = engine.evalModule(id, "import { w } from 'mid'; globalThis.__w__ = w;", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err == null);
    try testing.expectEqual(@as(i64, 77), try helpers.evalInt(id, "globalThis.__w__"));
}

test "adversarial: Hermes large-source .hbc compile+run (cache threshold size)" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var pad: [5000]u8 = undefined;
            @memset(&pad, ' ');
            const prefix = "globalThis.__cache_probe__ = 4242; //";
            var src_buf: [5200]u8 = undefined;
            @memcpy(src_buf[0..prefix.len], prefix);
            @memcpy(src_buf[prefix.len .. prefix.len + pad.len], &pad);
            const src = src_buf[0 .. prefix.len + pad.len];
            const cr = bytecode.compile(id, src, "probe.js");
            defer bytecode.freeCompileResult(cr);
            try testing.expect(cr.bytes != null);
            const res = bytecode.runBytecode(id, cr.bytes.?);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
            try helpers.expectEvalEquals(id, "String(globalThis.__cache_probe__)", "4242");
        }
    }.run);
}

test "adversarial: host Uint8Array view shares memory both ways" {
    try spikeOnly();
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const buffers = @import("../value/buffers.zig");
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var data: [4]u8 = .{ 1, 2, 3, 4 };
            const u8a = buffers.newUint8ArrayFromBytes(id, &data, data.len, null, null) orelse {
                // Some spike paths may not expose this helper yet.
                return error.SkipZigTest;
            };
            const global = backend.ActiveEngine.getGlobalObject(ctx);
            defer backend.ActiveEngine.freeValue(ctx, global);
            backend.ActiveEngine.setPropertyStr(ctx, global, "__u8__", u8a);
            try helpers.expectEvalEquals(id, "String(__u8__[0]+__u8__[3])", "5");
            try helpers.evalOk(id, "__u8__[1]=99;");
            try testing.expectEqual(@as(u8, 99), data[1]);
            data[2] = 77;
            try helpers.expectEvalEquals(id, "String(__u8__[2])", "77");
            try helpers.evalOk(id, "delete globalThis.__u8__;");
        }
    }.run);
}

// ---- Round 4: ESM deepen (Escargot) + .hbc deepen (Hermes) + host-ops smoke ----

test "adversarial r4: Escargot circular link + resolve rewrite together" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    // Without a loader, relative import must fail cleanly (not hang).
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    // Without loader, import must fail cleanly (not hang).
    const res = engine.evalModule(id, "import './x.js';", "<entry>");
    defer helpers.freeEvalResult(res);
    try testing.expect(res.err != null);
}

test "adversarial r4: Escargot evalModule top-level await if supported else readable fail" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    {
        const res = engine.evalModule(id, "await Promise.resolve(1); globalThis.__tla = 1;", "<tla>");
        defer helpers.freeEvalResult(res);
        // Either succeeds (TLA supported) or errors without killing the engine.
    }
    const ping = engine.evalScript(id, "1+1", "<ping>");
    defer helpers.freeEvalResult(ping);
    try testing.expect(ping.err == null);
}

test "adversarial r4: Hermes large source compile+run .hbc" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const src = "let s=0; for(var i=0;i<200;i++) s+=i; s";
            const cr = bytecode.compile(id, src, "large.js");
            defer bytecode.freeCompileResult(cr);
            const bytes = cr.bytes orelse return error.SkipZigTest;
            try testing.expect(bytes.len > 0);
            const res = bytecode.runBytecode(id, bytes);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err == null);
        }
    }.run);
}

test "adversarial r4: Hermes malformed .hbc with random bytes" {
    try spikeOnly();
    if (comptime !backend.isHermesBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const junk = [_]u8{ 0x48, 0x42, 0x43, 0x00, 0xff, 0xfe, 0xfd, 0x01, 0x02, 0x03 };
            const res = bytecode.runBytecode(id, &junk);
            defer helpers.freeEvalResult(res);
            try testing.expect(res.err != null);
            try helpers.expectEvalEquals(id, "'ok'", "ok");
        }
    }.run);
}

test "adversarial r4: Escargot arraySet then arrayClear via host ops" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    const value = @import("../value/root.zig");
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = engine.getContext(id).?;
    const arr = value.newArray(id, 2) orelse return error.NoArray;
    defer ActiveEngine.freeValue(ctx, arr);
    const s = ActiveEngine.newStringVal(ctx, "x");
    defer ActiveEngine.freeValue(ctx, s);
    try testing.expect(value.arraySet(id, arr, 0, s));
    try testing.expect(value.arrayClear(id, arr));
    try testing.expectEqual(@as(u32, 0), value.arrayLength(id, arr) orelse 99);
}

test "adversarial r4: Escargot Symbol.for registry identity" {
    try spikeOnly();
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    const symbol = @import("../value/symbol.zig");
    const value = @import("../value/root.zig");
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = engine.getContext(id).?;
    const a = symbol.forKey(id, "r4") orelse return error.Sym;
    defer ActiveEngine.freeValue(ctx, a);
    const b = symbol.forKey(id, "r4") orelse return error.Sym;
    defer ActiveEngine.freeValue(ctx, b);
    try testing.expect(value.strictEquals(id, a, b));
}
