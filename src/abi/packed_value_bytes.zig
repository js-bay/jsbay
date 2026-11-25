const backend = @import("../backend.zig");
const backend_dispatch = @import("../backend_dispatch.zig");
const instance_map = @import("../runtime/instance_map.zig");
const packed_api_value = @import("packed_api_value.zig");
const HyperValue = @import("hyper_box").Value;

pub const PackedDupResult = union(enum) {
    ok: usize,
    stale: void,
    out_of_memory: void,
};

fn packedHandlesOf(instance_id: i32) ?backend_dispatch.Handles {
    const inst = instance_map.getInstance(instance_id) orelse return null;
    return switch (inst.engine_handles) {
        .packed_alt => |a| .{ .runtime_addr = a.runtime_addr, .ctx_addr = a.ctx_addr },
        .mono => null,
    };
}

pub fn packedDupBytes(handle: u64, expect_instance: i32, expect_tag: backend.BackendType, out: []u8) PackedDupResult {
    const val = HyperValue{ .raw = handle };
    if (val.isSso()) {
        const sso_buf = val.asSsoBytes();
        const handles = packedHandlesOf(expect_instance) orelse return .stale;
        const res = backend_dispatch.valueNewString(expect_tag, handles.ctx_addr, sso_buf.slice());
        if (res.out_of_memory) return .out_of_memory;
        if (res.exception) |e| backend_dispatch.timerFreeValue(expect_tag, handles.ctx_addr, e.slice());
        if (res.value) |v| {
            if (out.len < v.len) {
                backend_dispatch.timerFreeValue(expect_tag, handles.ctx_addr, v.slice());
                return .out_of_memory;
            }
            @memcpy(out[0..v.len], v.bytes[0..v.len]);
            return .{ .ok = v.len };
        }
        return .stale;
    }
    const entry = packed_api_value.get(handle) orelse return .stale;
    if (entry.instance_id != expect_instance or entry.tag != expect_tag) return .stale;
    const len = backend_dispatch.timerDupValue(entry.tag, entry.ctx_addr, entry.bytes(), out) orelse return .stale;
    return .{ .ok = len };
}
