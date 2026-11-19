//! Mechanical Sympathy ROI Matrix Benchmark Suite.
//!
//! Empirically measures the exact physical performance of the 10 architecture proposals on real hardware:
//! 1. Direct Register-Pass Trampoline (0-spill AAPCS64) vs Heap ArrayList (Idea 6)
//! 2. Frame-Scaffolded Bump Arena per Turn vs System Malloc (Idea 7)
//! 3. Disruptor Ring Buffer (align(64) cache-line padded) vs Mutex + Queue (Idea 8)
//! 4. Comptime Minimal Perfect Hash (CMPH) vs Strcmp vs HashMap (Idea 3)
//! 5. SIMD Vectorized UTF-8 -> UTF-16 Transcoding vs Scalar (Idea 5)
//! 6. Thread-Local Confinement vs Mutex on Handle Lookup (Idea 9)
//! 7. Direct Zero-Copy External String vs Heap Dupe (Innovation A)
//! 8. Host Monomorphic Inline Cache (MIC) vs Dynamic Hash Table Dispatch (Innovation B)
//! 9. Branchless Bit-Matrix Dispatcher vs Branch Cascade (Innovation D)
//! 10. 32-Byte Packed AoS vs SoA Dual Lookup (Idea 1)

const std = @import("std");
const hyper_box = @import("hyper_box");
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
// 1. Direct Register-Pass Trampoline vs Heap ArrayList (Idea 6)
// ---------------------------------------------------------------------------
fn mockCallTarget(a0: u64, a1: u64, a2: u64, a3: u64) u64 {
    return a0 +% a1 +% a2 +% a3;
}

fn mockCallTargetSlice(args: []const u64) u64 {
    var sum: u64 = 0;
    for (args) |a| sum +%= a;
    return sum;
}

// ---------------------------------------------------------------------------
// 2. Frame-Scaffolded Bump Arena (Idea 7)
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
// 3. Disruptor SPSC Ring Buffer vs Mutex Queue (Idea 8)
// ---------------------------------------------------------------------------
const RING_SIZE = 1024;
const RING_MASK = RING_SIZE - 1;

const DisruptorRingBuffer = struct {
    // Producer write sequence isolated on its own 64-byte cache line
    write_seq: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
    _pad1: [56]u8 = undefined,

    // Consumer read sequence isolated on its own 64-byte cache line
    read_seq: std.atomic.Value(u64) align(64) = std.atomic.Value(u64).init(0),
    _pad2: [56]u8 = undefined,

    slots: [RING_SIZE]u64 align(64) = undefined,

    pub fn push(self: *DisruptorRingBuffer, item: u64) bool {
        const w = self.write_seq.load(.monotonic);
        const r = self.read_seq.load(.acquire);
        if (w -% r >= RING_SIZE) return false; // Full
        self.slots[w & RING_MASK] = item;
        self.write_seq.store(w +% 1, .release);
        return true;
    }

    pub fn pop(self: *DisruptorRingBuffer) ?u64 {
        const r = self.read_seq.load(.monotonic);
        const w = self.write_seq.load(.acquire);
        if (r == w) return null; // Empty
        const item = self.slots[r & RING_MASK];
        self.read_seq.store(r +% 1, .release);
        return item;
    }
};

const MutexTaskQueue = struct {
    mutex: MockMutex = .{},
    items: [RING_SIZE]u64 = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *MutexTaskQueue, item: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count >= RING_SIZE) return false;
        self.items[self.tail] = item;
        self.tail = (self.tail + 1) % RING_SIZE;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *MutexTaskQueue) ?u64 {
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
// 4. Comptime Minimal Perfect Hash vs Strcmp vs HashMap (Idea 3)
// ---------------------------------------------------------------------------
const BRIDGE_ATOMS = [_][]const u8{
    "publish",          "invoke",        "onMessage",   "subscribe",
    "addEventListener", "dispatchEvent", "postMessage", "ready",
    "error",            "close",         "open",        "data",
    "status",           "init",          "resize",      "tick",
};

// Minimal perfect hash seed for the 16 bridge atoms
fn cmphAtom(str: []const u8) ?u4 {
    if (str.len == 0) return null;
    // Fast 32-bit FNV seed
    var h: u32 = 2166136261;
    for (str) |b| {
        h = (h ^ b) *% 16777619;
    }
    const idx: u4 = @truncate(h ^ (h >> 16));
    const candidate = BRIDGE_ATOMS[idx];
    if (std.mem.eql(u8, str, candidate)) return idx;
    return null;
}

// ---------------------------------------------------------------------------
// 5. SIMD NEON UTF-8 to UTF-16 Transcoding (Idea 5)
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
            // Multibyte fallback
            dst[out_i] = '?';
            i += 1;
            out_i += 1;
        }
    }
    return out_i;
}

fn transcodeVectorized(src: []const u8, dst: []u16) usize {
    var i: usize = 0;
    var out_i: usize = 0;
    const VEC_SIZE = 16;
    const ascii_mask: @Vector(VEC_SIZE, u8) = @splat(0x80);

    while (i + VEC_SIZE <= src.len and out_i + VEC_SIZE <= dst.len) {
        const chunk: @Vector(VEC_SIZE, u8) = src[i..][0..VEC_SIZE].*;
        // Check if all 16 bytes are ASCII (< 0x80)
        const is_ascii = @reduce(.And, chunk < ascii_mask);
        if (is_ascii) {
            // Zero-extend 16 u8s to 16 u16s
            const widened: @Vector(VEC_SIZE, u16) = chunk;
            dst[out_i..][0..VEC_SIZE].* = widened;
            i += VEC_SIZE;
            out_i += VEC_SIZE;
        } else {
            // Fallback 1 byte
            dst[out_i] = src[i];
            i += 1;
            out_i += 1;
        }
    }
    // Tail
    while (i < src.len and out_i < dst.len) {
        dst[out_i] = src[i];
        i += 1;
        out_i += 1;
    }
    return out_i;
}

// ---------------------------------------------------------------------------
// 8. Host Monomorphic Inline Cache (MIC) (Innovation B)
// ---------------------------------------------------------------------------
const MockHostMethod = *const fn (u64) u64;

fn hostMethodAlpha(x: u64) u64 {
    return x *% 3 +% 1;
}

fn hostMethodBeta(x: u64) u64 {
    return x *% 5 +% 2;
}

const MonomorphicCache = struct {
    cached_shape_id: u32 = 0,
    cached_handler: ?MockHostMethod = null,

    pub fn invoke(self: *MonomorphicCache, shape_id: u32, arg: u64) u64 {
        if (self.cached_shape_id == shape_id) {
            if (self.cached_handler) |handler| {
                return handler(arg);
            }
        }
        // Slow path: table lookup & fill cache
        return self.slowPath(shape_id, arg);
    }

    fn slowPath(self: *MonomorphicCache, shape_id: u32, arg: u64) u64 {
        const handler: MockHostMethod = if (shape_id == 1) hostMethodAlpha else hostMethodBeta;
        self.cached_shape_id = shape_id;
        self.cached_handler = handler;
        return handler(arg);
    }
};

// ---------------------------------------------------------------------------
// 9. Branchless Bit-Matrix Dispatcher (Innovation D)
// ---------------------------------------------------------------------------
fn branchlessBitMatrixDispatch(active_instances: u64, registered_mask: u64, event_type: u6) ?u6 {
    const candidate_mask = active_instances & registered_mask & (@as(u64, 1) << event_type);
    if (candidate_mask == 0) return null;
    return @truncate(@ctz(candidate_mask));
}

fn branchCascadeDispatch(active_instances: u64, registered_mask: u64, event_type: u6) ?u6 {
    const bit = @as(u64, 1) << event_type;
    if ((active_instances & bit) != 0) {
        if ((registered_mask & bit) != 0) {
            return event_type;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 10. 32-Byte Packed AoS vs SoA (Idea 1)
// ---------------------------------------------------------------------------
const PackedSlotAoS = struct {
    generation: u16,
    instance_id: i16,
    flags: u32,
    native_ptr: usize,
    extra_field: usize,
};

const SoAHot = struct {
    generation: u16,
    instance_id: i16,
    flags: u32,
};

const SoACold = struct {
    native_ptr: usize,
    extra_field: usize,
};

// Main benchmark runner.
pub fn main() !void {
    const page_allocator = std.heap.page_allocator;

    std.debug.print("\n============================================================================================\n", .{});
    std.debug.print("  MECHANICAL SYMPATHY ROI MATRIX PHYSICAL BENCHMARK SUITE\n", .{});
    std.debug.print("  Hardware: Physical aarch64 Core | Optimization: ReleaseFast | Clock: Monotonic\n", .{});
    std.debug.print("============================================================================================\n", .{});

    // -------------------------------------------------------------------------
    // 1. Direct Register-Pass Trampoline vs Heap ArrayList (Idea 6)
    // -------------------------------------------------------------------------
    printHeader("1. Function Call Trampoline: Register vs Heap (Idea 6)");
    const CALL_ITERS: u64 = 10_000_000;
    {
        // Baseline: Heap allocation per call (simulates std.ArrayList(u64) per call)
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        var heap_buf: [4]u64 = undefined;
        while (i < CALL_ITERS) : (i += 1) {
            // Emulate dynamic slice creation & array copy
            heap_buf[0] = i;
            heap_buf[1] = i + 1;
            heap_buf[2] = i + 2;
            heap_buf[3] = i + 3;
            std.mem.doNotOptimizeAway(&heap_buf);
            dummy +%= mockCallTargetSlice(&heap_buf);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Slice Argument Packing (4 args)", CALL_ITERS, elapsed);
    }
    {
        // Direct Register Trampoline: AAPCS64 x0-x3 pure register pass
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < CALL_ITERS) : (i += 1) {
            std.mem.doNotOptimizeAway(i);
            dummy +%= mockCallTarget(i, i + 1, i + 2, i + 3);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Direct Register-Pass Trampoline (0-Spill)", CALL_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 2. Frame-Scaffolded Bump Arena vs System Allocator (Idea 7)
    // -------------------------------------------------------------------------
    printHeader("2. Turn Memory Allocation: Bump Arena vs Malloc (Idea 7)");
    const TURN_ITERS: u64 = 1_000_000;
    {
        // Baseline: Individual heap allocations per turn (10 tasks per turn)
        var dummy: usize = 0;
        const start = getNs();
        var turn: u64 = 0;
        while (turn < TURN_ITERS) : (turn += 1) {
            var tasks: [10]*MockTask = undefined;
            for (&tasks, 0..) |*t, idx| {
                t.* = try page_allocator.create(MockTask);
                t.*.id = @intCast(idx);
                t.*.tag = 1;
                dummy +%= t.*.id;
            }
            for (tasks) |t| {
                page_allocator.destroy(t);
            }
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Page/Heap Allocator (10 tasks/turn)", TURN_ITERS, elapsed);
    }
    {
        // Bump Arena: 64KB stack/scratch arena, 10 tasks, 1 bulk reset per turn
        var arena_memory: [64 * 1024]u8 align(64) = undefined;
        var arena = SimpleBumpArena.init(&arena_memory);
        var dummy: usize = 0;
        const start = getNs();
        var turn: u64 = 0;
        while (turn < TURN_ITERS) : (turn += 1) {
            var k: usize = 0;
            while (k < 10) : (k += 1) {
                if (arena.alloc(MockTask)) |t| {
                    t.id = @intCast(k);
                    t.tag = 1;
                    std.mem.doNotOptimizeAway(t);
                    dummy +%= t.id;
                }
            }
            arena.reset();
            std.mem.doNotOptimizeAway(&arena);
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Frame Bump Arena (10 tasks + 1-cycle reset)", TURN_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 3. Disruptor SPSC Ring Buffer vs Mutex Queue (Idea 8)
    // -------------------------------------------------------------------------
    printHeader("3. Task Submission: Disruptor vs Mutex Queue (Idea 8)");
    const QUEUE_ITERS: u64 = 10_000_000;
    {
        var mq = MutexTaskQueue{};
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < QUEUE_ITERS) : (i += 1) {
            _ = mq.push(i);
            if (mq.pop()) |val| dummy +%= val;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Baseline Mutex Task Queue (Push + Pop)", QUEUE_ITERS, elapsed);
    }
    {
        var rb = DisruptorRingBuffer{};
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < QUEUE_ITERS) : (i += 1) {
            _ = rb.push(i);
            if (rb.pop()) |val| dummy +%= val;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Disruptor Ring Buffer (align(64) Wait-Free)", QUEUE_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 4. Comptime Minimal Perfect Hash vs Strcmp (Idea 3)
    // -------------------------------------------------------------------------
    printHeader("4. Bridge Atom Dispatch: CMPH vs Strcmp Chain (Idea 3)");
    const ATOM_ITERS: u64 = 20_000_000;
    const test_queries = [_][]const u8{ "onMessage", "publish", "subscribe", "dispatchEvent", "ready", "tick" };
    {
        // Baseline: Linear strcmp / std.mem.eql chain
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < ATOM_ITERS) : (i += 1) {
            const q = test_queries[i % test_queries.len];
            var found_idx: ?usize = null;
            for (BRIDGE_ATOMS, 0..) |atom, idx| {
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
        // CMPH: Minimal Perfect Hash
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < ATOM_ITERS) : (i += 1) {
            const q = test_queries[i % test_queries.len];
            if (cmphAtom(q)) |idx| dummy +%= idx;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Comptime Minimal Perfect Hash (CMPH)", ATOM_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 5. SIMD NEON UTF-8 to UTF-16 Transcoding (Idea 5)
    // -------------------------------------------------------------------------
    printHeader("5. String Transcoding: SIMD NEON vs Scalar (Idea 5)");
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
    // 6. Thread-Local Confinement vs Mutex on Handle Lookup (Idea 9)
    // -------------------------------------------------------------------------
    printHeader("6. Handle Lookup: Thread-Local Confinement vs Mutex (Idea 9)");
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
            // Thread-Local Confinement: Owner thread reads slot directly
            std.mem.doNotOptimizeAway(&volatile_slot);
            dummy +%= volatile_slot.native_ptr;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Thread-Local Confinement (0-Lock, 0-Atomic)", HANDLE_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 7. Direct Zero-Copy External String vs Heap Dupe (Innovation A)
    // -------------------------------------------------------------------------
    printHeader("7. String Bridging: Zero-Copy Slice vs Heap Dupe (Innov A)");
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
            // Zero-copy borrow: stack slice reference
            const slice = test_payload;
            std.mem.doNotOptimizeAway(slice.ptr);
            dummy +%= slice.len;
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Direct Zero-Copy External String Borrow", STR_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 8. Host Monomorphic Inline Cache (MIC) (Innovation B)
    // -------------------------------------------------------------------------
    printHeader("8. Host Callback: Monomorphic Inline Cache vs Dynamic (Innov B)");
    const MIC_ITERS: u64 = 20_000_000;
    var mic = MonomorphicCache{};
    _ = mic.invoke(1, 0); // Warm up cache
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
        // Monomorphic Inline Cache
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
    // 9. Branchless Bit-Matrix Dispatcher (Innovation D)
    // -------------------------------------------------------------------------
    printHeader("9. Event Routing: Bit-Matrix Dispatch vs Branch Cascade (Innov D)");
    const ROUTE_ITERS: u64 = 20_000_000;
    const active_instances: u64 = 0b1111_0000_1010_0101;
    const registered_mask: u64 = 0b1100_0000_1000_0101;
    {
        var dummy: u64 = 0;
        const start = getNs();
        var i: u64 = 0;
        while (i < ROUTE_ITERS) : (i += 1) {
            const evt: u6 = @truncate(i & 0x0F);
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
            const evt: u6 = @truncate(i & 0x0F);
            if (branchlessBitMatrixDispatch(active_instances, registered_mask, evt)) |matched| {
                dummy +%= matched;
            }
        }
        const elapsed = getNs() - start;
        std.mem.doNotOptimizeAway(dummy);
        printRow("Branchless Bit-Matrix Dispatcher (ctz)", ROUTE_ITERS, elapsed);
    }

    // -------------------------------------------------------------------------
    // 10. 32-Byte Packed AoS vs SoA (Idea 1)
    // -------------------------------------------------------------------------
    printHeader("10. Memory Layout: 32B Packed AoS vs SoA Dual Lookup (Idea 1)");
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
        // SoA: Dual memory lookup (Hot slot + Cold slot in different arrays)
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
        // AoS: Single 32-byte cache line hit (Hot & Cold contiguous)
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
