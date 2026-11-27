pub fn finishBoolOp(
    comptime Operations: type,
    comptime freeValue: anytype,
    op: *Operations.ApiOp,
    result: anytype,
    out_flag: *bool,
    out_exception: *u64,
    status: anytype,
) c_int {
    if (!Operations.drainApiJobs(op)) {
        if (result == .exception) freeValue(op.ctx, result.exception);
        return status.instance_not_found;
    }
    return switch (result) {
        .ok => |value| blk: {
            out_flag.* = value;
            break :blk status.ok;
        },
        .exception => |exception| blk: {
            const stored = Operations.apiStore(op.id, exception, out_exception);
            break :blk if (stored == status.ok) 1 else stored;
        },
        .out_of_memory => status.out_of_memory,
    };
}
