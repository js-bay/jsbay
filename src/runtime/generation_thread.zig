pub fn isEngineThreadForGeneration(
    instance_id: i32,
    generation: u64,
    comptime retain: anytype,
    comptime release: anytype,
    comptime isEngineThread: anytype,
) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    return state.generation == generation and isEngineThread(state);
}

pub fn runDeferredDrain(instance_id: i32, comptime generationOf: anytype, comptime drain: anytype) void {
    const generation = generationOf(instance_id) orelse return;
    drain(instance_id, generation);
}
