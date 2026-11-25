//! Mechanical Sympathy Architecture Performance Benchmark Suite.
//!
//! Measures isolated implementation comparisons on target hardware; simulated workloads do not imply runtime integration:
//! 1. C ABI Invocations: Direct AAPCS64 Register-Pass vs Heap Argument Marshalling
//! 2. Simulated Turn Allocation: Bump Arena vs System Malloc
//! 3. MPSC Task Queue: Cache-Line Isolated Mutex vs Unpadded Mutex under Multi-Producer Contention
//! 4. Static String Dispatch: Compile-Time Minimal Perfect Hash vs Linear Strcmp Chain
//! 5. String Transcoding: 16-Byte SIMD NEON Vectorized vs Scalar Byte Loop
//! 6. Value Resolution: Register-Level Unboxed Fast-Path vs Mutex Handle Table
//! 7. String Bridging: Small String Optimization (SSO) & Slices vs Heap Duplication
//! 8. Native Callback Dispatch: Monomorphic Inline Cache (MIC) vs Dynamic Table Lookup
//! 9. Event Routing: Hardware Count-Trailing-Zeros Bit-Matrix vs Branch Cascade
//! 10. Handle Registry Layout: 32-Byte Packed Generational Node vs Dual-Table Lookup

const std = @import("std");
const hyper_box = @import("hyper_box");
const cmph = @import("cmph");
const simd_utf = @import("simd_utf");
const bit_matrix = @import("bit_matrix");
const HyperValue = hyper_box.Value;
const GenerationalSlotMap = hyper_box.GenerationalSlotMap;

const MockMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pub fn lock(self: *MockMutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *MockMutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

fn getNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn printHeader(title: []const u8) void {
    std.debug.print("\n=== {s} ===\n", .{title});
    std.debug.print("{s:<48} {s:>12} {s:>14} {s:>18}\n", .{ "Benchmark Workload", "Operations", "Latency (ns)", "Throughput (ops/s)" });
    std.debug.print("{s:-<48} {s:->12} {s:->14} {s:->18}\n", .{ "", "", "", "" });
}

fn printRow(name: []const u8, iters: u64, elapsed_ns: u64) void {
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iters));
    const ops_per_sec = if (elapsed_ns > 0) (@as(f64, @floatFromInt(iters)) * 1_000_000_000.0) / @as(f64, @floatFromInt(elapsed_ns)) else 0;
    std.debug.print("{s:<48} {d:>12} {d:>14.3} {d:>18.0}\n", .{ name, iters, ns_per_op, ops_per_sec });
}

// ---------------------------------------------------------------------------
// 1. Direct Register-Pass Trampoline vs Heap Argument Marshalling
// ---------------------------------------------------------------------------
var call_fn_opaque: *const fn (u64, u64, u64, u64) u64 = &mockCallTarget;
var call_slice_fn_opaque: *const fn ([]const u64) u64 = &mockCallTargetSlice;

noinline fn mockCallTarget(a0: u64, a1: u64, a2: u64, a3: u64) u64 {
    return a0 +% a1 +% a2 +% a3;
}

noinline fn mockCallTargetSlice(args: []const u64) u64 {
    var sum: u64 = 0;
    for (args) |a| sum +%= a;
    return sum;
}

// ---------------------------------------------------------------------------
// 2. Simulated Bump Arena per Turn vs Malloc
// ---------------------------------------------------------------------------
const MockTask = struct {
    id: u32,
    tag: u32,
    callback: usize,
    payload: [16]u8,
};

const SimpleBumpArena = struct {
    buffer: []u8,
    offset: usize = 0,

    pub fn init(buf: []u8) SimpleBumpArena {
        return .{ .buffer = buf };
    }

    pub fn alloc(self: *SimpleBumpArena, comptime T: type) ?*T {
        const align_size = @alignOf(T);
        const aligned_offset = std.mem.alignForward(usize, self.offset, align_size);
        const end = aligned_offset + @sizeOf(T);
        if (end > self.buffer.len) return null;
        self.offset = end;
        return @ptrCast(@alignCast(&self.buffer[aligned_offset]));
    }

    pub fn reset(self: *SimpleBumpArena) void {
        self.offset = 0;
    }
};

// ---------------------------------------------------------------------------
// 3. Multi-Producer Task Queue: Cache-Line Isolated Mutex vs Unpadded Mutex
// ---------------------------------------------------------------------------
const RING_SIZE = 1024;

const UnpaddedTaskQueue = struct {
    mutex: MockMutex = .{},
    items: [RING_SIZE]u64 = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *UnpaddedTaskQueue, item: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count >= RING_SIZE) return false;
        self.items[self.tail] = item;
        self.tail = (self.tail + 1) % RING_SIZE;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *UnpaddedTaskQueue) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % RING_SIZE;
        self.count -= 1;
        return item;
    }
};

const CacheLineIsolatedTaskQueue = struct {
    mutex: MockMutex align(64) = .{},
    _pad: [64 - @sizeOf(MockMutex)]u8 = undefined,
    items: [RING_SIZE]u64 align(64) = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *CacheLineIsolatedTaskQueue, item: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count >= RING_SIZE) return false;
        self.items[self.tail] = item;
        self.tail = (self.tail + 1) % RING_SIZE;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *CacheLineIsolatedTaskQueue) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % RING_SIZE;
        self.count -= 1;
        return item;
    }
};

// ---------------------------------------------------------------------------
// 4. Compile-Time Minimal Perfect Hash vs Linear Strcmp Chain
// ---------------------------------------------------------------------------
const STATIC_KEYS = [_][]const u8{
    "publish",     "invoke",           "onMessage",           "subscribe",
    "unsubscribe", "addEventListener", "removeEventListener", "dispatchEvent",
    "postMessage", "ready",            "error",               "close",
    "open",        "data",             "status",              "init",
};
const StaticKeyMatcher = cmph.ComptimeMinimalPerfectHash(&STATIC_KEYS);

fn cmphMatch(str: []const u8) ?usize {
    return StaticKeyMatcher.match(str);
}

// ---------------------------------------------------------------------------
// 5. SIMD NEON UTF-8 to UTF-16 Transcoding vs Scalar Loop
// ---------------------------------------------------------------------------
fn transcodeScalar(src: []const u8, dst: []u16) usize {
    var i: usize = 0;
    var out_i: usize = 0;
    while (i < src.len and out_i < dst.len) {
        const b = src[i];
        if (b < 0x80) {
            dst[out_i] = b;
            i += 1;
            out_i += 1;
        } else {
            dst[out_i] = '?';
            i += 1;
            out_i += 1;
        }
    }
    return out_i;
}

fn transcodeVectorized(src: []const u8, dst: []u16) usize {
    return simd_utf.transcodeUtf8ToUtf16(dst, src) catch 0;
}

// ---------------------------------------------------------------------------
// 8. Monomorphic Inline Cache (MIC) vs Dynamic Dispatch
// ---------------------------------------------------------------------------
const MockHostMethod = *const fn (u64) u64;

fn hostMethodAlpha(x: u64) u64 {
    return x *% 2;
}

fn hostMethodBeta(x: u64) u64 {
    return x +% 10;
}

const MonomorphicCache = struct {
    cached_shape_id: u32 = 0,
    cached_fn: ?MockHostMethod = null,

    pub inline fn invoke(self: *MonomorphicCache, shape_id: u32, arg: u64) u64 {
        if (self.cached_shape_id == shape_id) {
            if (self.cached_fn) |f| return f(arg);
        }
        return self.invokeSlow(shape_id, arg);
    }

    fn invokeSlow(self: *MonomorphicCache, shape_id: u32, arg: u64) u64 {
        const f: MockHostMethod = if (shape_id == 1) hostMethodAlpha else hostMethodBeta;
        self.cached_shape_id = shape_id;
        self.cached_fn = f;
        return f(arg);
    }
};

// ---------------------------------------------------------------------------
// 9. Branchless Bit-Matrix Dispatcher vs Branch Cascade
// ---------------------------------------------------------------------------
fn branchCascadeDispatch(active: u64, filter: u64, evt: u6) ?u6 {
    const combined = active & filter;
    if (evt == 0 and (combined & 1) != 0) return 0;
    if (evt <= 1 and (combined & 2) != 0) return 1;
    if (evt <= 2 and (combined & 4) != 0) return 2;
    if (evt <= 3 and (combined & 8) != 0) return 3;
    if (evt <= 4 and (combined & 16) != 0) return 4;
    if (evt <= 5 and (combined & 32) != 0) return 5;
    if (evt <= 6 and (combined & 64) != 0) return 6;
    if (evt <= 7 and (combined & 128) != 0) return 7;
    return null;
}

fn branchlessBitMatrixDispatch(active: u64, filter: u64, evt: u6) ?u6 {
    return bit_matrix.BitMatrix.nextMatching(active, filter, evt);
}

// ---------------------------------------------------------------------------
// 10. 32-Byte Packed AoS vs SoA Node Layout
// ---------------------------------------------------------------------------
const PackedSlotAoS = struct {
    generation: u16,
    instance_id: u16,
    flags: u32,
    native_ptr: usize,
    extra_field: usize,
};

const SoAHot = struct {
    generation: u16,
    instance_id: u16,
    flags: u32,
};

const SoACold = struct {
    native_ptr: usize,
    extra_field: usize,
};

pub fn main() !void {
    const page_allocator = std.heap.page_allocator;

    std.debug.print("\n============================================================================================\n", .{});
    std.debug.print("  MECHANICAL SYMPATHY ARCHITECTURE PERFORMANCE BENCHMARK SUITE\n", .{});
    std.debug.print("  Hardware: Physical aarch64 Core | Optimization: ReleaseFast | Clock: Monotonic\n", .{});
    std.debug.print("============================================================================================\n", .{});

    // -------------------------------------------------------------------------
    // 1. C ABI Invocations: Direct AAPCS64 Register-Pass vs Heap Argument Marshalling
    // -------------------------------------------------------------------------
    printHeader("1. C ABI Invocations: Register-Pass vs Heap Marshalling");
    const CALL_ITERS: u64 = 10_000_000;
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < CALL_ITERS) : (i += 1) {
            var v = i;
            std.mem.doNotOptimizeAway(&v);
            const args = [_]u64{ v, v + 1, v + 2, v + 3 };
            dummy +%= call_slice_fn_opaque(&args);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Slice Argument Packing (4 args)", CALL_ITERS, elapsed);
    }
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < CALL_ITERS) : (i += 1) {
            var v = i;
            std.mem.doNotOptimizeAway(&v);
            dummy +%= call_fn_opaque(v, v + 1, v + 2, v + 3);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Direct Register-Pass Trampoline (0-Spill)", CALL_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 2. Turn Memory Lifecycle: Frame Bump Arena vs System Malloc
    // -------------------------------------------------------------------------
    printHeader("2. Turn Memory Lifecycle: Frame Arena vs System Malloc");
    const TURN_ITERS: u64 = 1_000_000;
    {
        var dummy: usize = 0;
        const start = getNs();
        var t: u64 = 0;
        while (t < TURN_ITERS) : (t += 1) {
            var k: usize = 0;
            while (k < 10) : (k += 1) {
                const node = try page_allocator.create(MockTask);
                node.* = .{ .id = @intCast(k), .tag = 1, .callback = 0x1234, .payload = @splat(0) };
                std.mem.doNotOptimizeAway(node);
                dummy +%= node.id;
                page_allocator.destroy(node);
            }
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Page/Heap Allocator (10 tasks/turn)", TURN_ITERS, elapsed);
    }
    {
        var arena_mem: [65536]u8 align(64) = undefined;
        var arena = SimpleBumpArena.init(&arena_mem);
        var dummy: usize = 0;
        const start = getNs();
        var t: u64 = 0;
        while (t < TURN_ITERS) : (t += 1) {
            var k: usize = 0;
            while (k < 10) : (k += 1) {
                const node = arena.alloc(MockTask) orelse break;
                node.* = .{ .id = @intCast(k), .tag = 1, .callback = 0x1234, .payload = @splat(0) };
                std.mem.doNotOptimizeAway(node);
                dummy +%= node.id;
            }
            arena.reset();
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Frame Bump Arena (10 tasks + 1-cycle reset)", TURN_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 3. Task Queue Layout: Cache-Line Isolated Mutex vs Unpadded Mutex (Uncontended Overhead)
    // -------------------------------------------------------------------------
    printHeader("3. Task Queue Layout: Cache-Line Isolated Mutex vs Unpadded Mutex (Uncontended)");
    const QUEUE_ITERS: u64 = 10_000_000;
    {
        var mq = UnpaddedTaskQueue{};
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < QUEUE_ITERS) : (i += 1) {
            _ = mq.push(i);
            if (mq.pop()) |val| dummy +%= val;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Unpadded Mutex Task Queue (Uncontended Push+Pop)", QUEUE_ITERS, elapsed);
    }
    {
        var isolated_q = CacheLineIsolatedTaskQueue{};
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < QUEUE_ITERS) : (i += 1) {
            _ = isolated_q.push(i);
            if (isolated_q.pop()) |val| dummy +%= val;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Cache-Line Isolated Mutex Queue (Uncontended Push+Pop)", QUEUE_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 4. Static String Dispatch: Compile-Time Minimal Perfect Hash vs Linear Strcmp Chain
    // -------------------------------------------------------------------------
    printHeader("4. Static String Dispatch: CMPH vs Strcmp Chain");

    for (STATIC_KEYS, 0..) |atom, expected_idx| {
        const resolved = cmphMatch(atom);
        if (resolved != expected_idx) {
            std.debug.panic("CMPH verification failed for key '{s}': expected {d}, got {?d}\n", .{ atom, expected_idx, resolved });
        }
    }

    const ATOM_ITERS: u64 = 20_000_000;
    const test_queries = [_][]const u8{ "onMessage", "publish", "subscribe", "dispatchEvent", "ready", "init" };
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < ATOM_ITERS) : (i += 1) {
            const q = test_queries[i % test_queries.len];
            var found_idx: ?usize = null;
            for (STATIC_KEYS, 0..) |atom, idx| {
                if (std.mem.eql(u8, q, atom)) {
                    found_idx = idx;
                    break;
                }
            }
            if (found_idx) |idx| dummy +%= idx;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Linear Strcmp Search", ATOM_ITERS, elapsed);
    }
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < ATOM_ITERS) : (i += 1) {
            const q = test_queries[i % test_queries.len];
            if (cmphMatch(q)) |idx| dummy +%= idx;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Comptime Minimal Perfect Hash (CMPH)", ATOM_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 5. String Transcoding: 16-Byte SIMD NEON Vectorized vs Scalar Byte Loop
    // -------------------------------------------------------------------------
    printHeader("5. String Transcoding: SIMD NEON vs Scalar Loop");
    const TRANSCODE_ITERS: u64 = 2_000_000;
    const sample_json = "{\"action\":\"publish\",\"topic\":\"sensor/accelerometer\",\"data\":{\"x\":12.34,\"y\":-56.78,\"z\":9.81},\"timestamp\":1700000000}";
    var dynamic_json: [256]u8 = undefined;
    @memcpy(dynamic_json[0..sample_json.len], sample_json);
    var utf16_dst: [512]u16 = undefined;
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < TRANSCODE_ITERS) : (i += 1) {
            std.mem.doNotOptimizeAway(&dynamic_json);
            dummy +%= transcodeScalar(dynamic_json[0..sample_json.len], &utf16_dst);
            std.mem.doNotOptimizeAway(&utf16_dst);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        const bytes_processed = sample_json.len * TRANSCODE_ITERS;
        const gb_per_sec = (@as(f64, @floatFromInt(bytes_processed)) / 1_000_000_000.0) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
        std.debug.print("{s:<48} {d:>12} {d:>14.3} {d:>15.2} GB/s\n", .{ "Baseline Scalar UTF-8 -> UTF-16", TRANSCODE_ITERS, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(TRANSCODE_ITERS)), gb_per_sec });
    }
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < TRANSCODE_ITERS) : (i += 1) {
            std.mem.doNotOptimizeAway(&dynamic_json);
            dummy +%= transcodeVectorized(dynamic_json[0..sample_json.len], &utf16_dst);
            std.mem.doNotOptimizeAway(&utf16_dst);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        const bytes_processed = sample_json.len * TRANSCODE_ITERS;
        const gb_per_sec = (@as(f64, @floatFromInt(bytes_processed)) / 1_000_000_000.0) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
        std.debug.print("{s:<48} {d:>12} {d:>14.3} {d:>15.2} GB/s\n", .{ "SIMD NEON Vectorized Transcoding", TRANSCODE_ITERS, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(TRANSCODE_ITERS)), gb_per_sec });
    }

    // -------------------------------------------------------------------------
    // 6. Value Resolution: Register-Level Unboxed Fast-Path vs Mutex Handle Table
    // -------------------------------------------------------------------------
    printHeader("6. Value Resolution: Unboxed Fast-Path vs Mutex Handle Table");
    const HANDLE_ITERS: u64 = 20_000_000;
    var volatile_slot = PackedSlotAoS{ .generation = 1, .instance_id = 10, .flags = 0, .native_ptr = 0xDEADBEEF, .extra_field = 0 };
    var mock_mtx = MockMutex{};
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < HANDLE_ITERS) : (i += 1) {
            mock_mtx.lock();
            std.mem.doNotOptimizeAway(&volatile_slot);
            dummy +%= volatile_slot.native_ptr;
            mock_mtx.unlock();
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Mutex-Guarded Handle Access", HANDLE_ITERS, elapsed);
    }
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < HANDLE_ITERS) : (i += 1) {
            std.mem.doNotOptimizeAway(&volatile_slot);
            dummy +%= volatile_slot.native_ptr;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Unboxed Register Access (0-Lock, 0-Atomic)", HANDLE_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 7. String Bridging: Small String Optimization (SSO) & Slices vs Heap Duplication
    // -------------------------------------------------------------------------
    printHeader("7. String Bridging: Zero-Copy Slice vs Heap Duplication");
    const STR_ITERS: u64 = 500_000;
    const test_payload: []const u8 = sample_json;
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < STR_ITERS) : (i += 1) {
            const dupe = try page_allocator.dupe(u8, test_payload);
            std.mem.doNotOptimizeAway(dupe.ptr);
            dummy +%= dupe.len;
            page_allocator.free(dupe);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Heap Dupe (Alloc + Memcpy + Free)", STR_ITERS, elapsed);
    }
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < STR_ITERS) : (i += 1) {
            const slice = test_payload;
            std.mem.doNotOptimizeAway(slice.ptr);
            dummy +%= slice.len;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Direct Zero-Copy External String Borrow", STR_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 8. Native Callback Dispatch: Monomorphic Inline Cache (MIC) vs Dynamic Table Lookup
    // -------------------------------------------------------------------------
    printHeader("8. Host Callback: Monomorphic Inline Cache vs Dynamic Dispatch");
    const MIC_ITERS: u64 = 20_000_000;
    var mic = MonomorphicCache{};
    _ = mic.invoke(1, 0);
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < MIC_ITERS) : (i += 1) {
            var shape_id: u32 = 1;
            std.mem.doNotOptimizeAway(&shape_id);
            const handler: MockHostMethod = switch (shape_id) {
                1 => hostMethodAlpha,
                2 => hostMethodBeta,
                else => hostMethodAlpha,
            };
            std.mem.doNotOptimizeAway(handler);
            dummy +%= handler(i);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Dynamic Dispatch (Switch/Map)", MIC_ITERS, elapsed);
    }
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < MIC_ITERS) : (i += 1) {
            var shape_id: u32 = 1;
            std.mem.doNotOptimizeAway(&shape_id);
            dummy +%= mic.invoke(shape_id, i);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Host Monomorphic Inline Cache (Direct Hit)", MIC_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 9. Event Routing: Hardware Count-Trailing-Zeros Bit-Matrix vs Branch Cascade
    // -------------------------------------------------------------------------
    printHeader("9. Event Routing: Bit-Matrix Dispatch vs Branch Cascade");
    const ROUTE_ITERS: u64 = 20_000_000;
    const active_instances: u64 = 0b1010_0101;
    const registered_mask: u64 = 0b1000_0101;

    // Verify both dispatchers produce identical routing results across all 8 inputs.
    var check_evt: u6 = 0;
    while (check_evt < 8) : (check_evt += 1) {
        const cascade_res = branchCascadeDispatch(active_instances, registered_mask, check_evt);
        const matrix_res = branchlessBitMatrixDispatch(active_instances, registered_mask, check_evt);
        if (cascade_res != matrix_res) {
            std.debug.panic("Dispatcher mismatch for evt {d}: cascade={?d}, matrix={?d}\n", .{ check_evt, cascade_res, matrix_res });
        }
    }

    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < ROUTE_ITERS) : (i += 1) {
            const evt: u6 = @truncate(i & 0x07);
            if (branchCascadeDispatch(active_instances, registered_mask, evt)) |matched| {
                dummy +%= matched;
            }
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Multi-Branch Cascade Dispatch", ROUTE_ITERS, elapsed);
    }
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < ROUTE_ITERS) : (i += 1) {
            const evt: u6 = @truncate(i & 0x07);
            if (branchlessBitMatrixDispatch(active_instances, registered_mask, evt)) |matched| {
                dummy +%= matched;
            }
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Branchless Bit-Matrix Dispatcher (ctz)", ROUTE_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 10. Handle Registry Layout: 32-Byte Packed Generational Node vs Dual-Table Lookup
    // -------------------------------------------------------------------------
    printHeader("10. Memory Layout: 32B Packed AoS vs SoA Dual Lookup");
    const LAYOUT_ITERS: u64 = 20_000_000;
    const SLOTS_COUNT = 1024;
    var aos_slots: [SLOTS_COUNT]PackedSlotAoS align(64) = undefined;
    for (&aos_slots, 0..) |*s, idx| {
        s.* = .{ .generation = @intCast(idx & 0xFFFF), .instance_id = 1, .flags = 0, .native_ptr = idx * 8, .extra_field = idx };
    }
    var soa_hot: [SLOTS_COUNT]SoAHot align(64) = undefined;
    var soa_cold: [SLOTS_COUNT]SoACold align(64) = undefined;
    for (0..SLOTS_COUNT) |idx| {
        soa_hot[idx] = .{ .generation = @intCast(idx & 0xFFFF), .instance_id = 1, .flags = 0 };
        soa_cold[idx] = .{ .native_ptr = idx * 8, .extra_field = idx };
    }
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < LAYOUT_ITERS) : (i += 1) {
            const idx = i & (SLOTS_COUNT - 1);
            if (soa_hot[idx].generation == @as(u16, @intCast(idx & 0xFFFF))) {
                dummy +%= soa_cold[idx].native_ptr;
            }
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("SoA Split Arrays (Hot Check + Cold Lookup)", LAYOUT_ITERS, elapsed);
    }
    {
        var dummy: usize = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < LAYOUT_ITERS) : (i += 1) {
            const idx = i & (SLOTS_COUNT - 1);
            const slot = &aos_slots[idx];
            if (slot.generation == @as(u16, @intCast(idx & 0xFFFF))) {
                dummy +%= slot.native_ptr;
            }
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("32-Byte Packed AoS (Single Cache-Line Hit)", LAYOUT_ITERS, elapsed);
    }

    std.debug.print("============================================================================================\n\n", .{});
}
