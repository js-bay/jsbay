//! Host object property traps.
//!
//! Unknown gets are undefined. Set writes host storage; with no set callback the write throws a plain Error whose message starts with "TypeError: " and whose name is not "TypeError". Callback errors become JS exceptions and leave the runtime able to eval `1+1`. Enumeration is only `get_property_names`, with integer indices ascending first. `in` and `hasOwnProperty` are true for a name that is not in that list. Callbacks see the instance id from create. The finalizer does not call back into the engine.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const host_object = @import("../value/host_object.zig");
const host_value = @import("../abi/host_value.zig");

const ActiveEngine = backend.ActiveEngine;

const Bag = struct {
    bytes: [64]u8 = undefined,
    len: usize = 0,
    id: i32 = -1,
    gets: u32 = 0,
    sets: u32 = 0,
};

fn bagGet(instance_id: i32, user_data: ?*anyopaque, name: []const u8, out: *host_value.HostValue) ?[*:0]const u8 {
    const bag: *Bag = @ptrCast(@alignCast(user_data.?));
    bag.id = instance_id;
    bag.gets += 1;
    host_value.clear(out);
    if (!std.mem.eql(u8, name, "thing")) return null;
    out.tag = host_value.tag_string;
    out.ptr = bag.bytes[0..].ptr;
    out.len = bag.len;
    return null;
}

fn bagSet(instance_id: i32, user_data: ?*anyopaque, name: []const u8, value: host_value.HostValue) ?[*:0]const u8 {
    const bag: *Bag = @ptrCast(@alignCast(user_data.?));
    bag.id = instance_id;
    bag.sets += 1;
    if (!std.mem.eql(u8, name, "thing")) return null;
    if (value.tag != host_value.tag_string) return "thing must be a string";
    const src = (value.ptr orelse return "missing bytes")[0..value.len];
    if (src.len > bag.bytes.len) return "too long";
    @memcpy(bag.bytes[0..src.len], src);
    bag.len = src.len;
    return null;
}

const listed_names = [_][]const u8{ "prop1", "prop2" };

fn listNames(instance_id: i32, user_data: ?*anyopaque, out_names: *[]const []const u8) void {
    const bag: *Bag = @ptrCast(@alignCast(user_data.?));
    bag.id = instance_id;
    out_names.* = listed_names[0..];
}

fn install(id: i32, user_data: ?*anyopaque, callbacks: host_object.Callbacks) !void {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const obj = host_object.create(id, user_data, callbacks) orelse return error.HostCreateFailed;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, "ho", obj);
}

test "host object: unknown get is undefined and set stores on the host" {
    var bag = Bag{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try install(id, @ptrCast(&bag), .{
        .get = bagGet,
        .set = bagSet,
    });

    try helpers.evalOk(id, "if (ho.missing !== undefined) throw new Error('missing');");
    try helpers.evalOk(id, "ho.thing = 'hello'; if (ho.thing !== 'hello') throw new Error(String(ho.thing));");
    try testing.expectEqualStrings("hello", bag.bytes[0..bag.len]);
    try testing.expect(bag.sets >= 1);
    try testing.expectEqual(id, bag.id);
}

fn failGet(_: i32, _: ?*anyopaque, _: []const u8, out: *host_value.HostValue) ?[*:0]const u8 {
    host_value.clear(out);
    return "Cannot get";
}

fn failSet(_: i32, _: ?*anyopaque, _: []const u8, _: host_value.HostValue) ?[*:0]const u8 {
    return "Cannot set";
}

test "host object: missing set throws TypeError and eval still works" {
    var bag = Bag{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try install(id, @ptrCast(&bag), .{ .get = bagGet });

    const res = engine.evalScript(id, "ho.thing = 'x';", "<set>");
    defer helpers.freeEvalResult(res);
    const err = res.err orelse return error.ExpectedTypeError;
    try testing.expect(std.mem.indexOf(u8, err, "TypeError") != null);
    try helpers.evalOk(id,
        \\var seen = null;
        \\try { ho.thing = "y"; } catch (e) { seen = e; }
        \\if (!seen) throw new Error("no throw");
        \\if (seen.name === "TypeError") throw new Error("name " + seen.name);
        \\if (typeof seen.message !== "string" || !seen.message.startsWith("TypeError: ")) throw new Error("msg " + seen.message);
    );
    try helpers.expectEvalEquals(id, "1+1", "2");
}

test "host object: get and set errors become exceptions and 1+1 is 2" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try install(id, null, .{ .get = failGet, .set = failSet });

    const got = engine.evalScript(id, "ho.thing", "<get>");
    defer helpers.freeEvalResult(got);
    const get_err = got.err orelse return error.ExpectedGetError;
    try testing.expect(std.mem.indexOf(u8, get_err, "Cannot get") != null);
    try helpers.expectEvalEquals(id, "1+1", "2");

    const set = engine.evalScript(id, "ho.thing = 'x';", "<set>");
    defer helpers.freeEvalResult(set);
    const set_err = set.err orelse return error.ExpectedSetError;
    try testing.expect(std.mem.indexOf(u8, set_err, "Cannot set") != null);
    try helpers.expectEvalEquals(id, "1+1", "2");
}

test "host object: enumeration is the name list but in and hasOwnProperty are true" {
    var bag = Bag{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try install(id, @ptrCast(&bag), .{
        .get = bagGet,
        .set = bagSet,
        .get_property_names = listNames,
    });

    try helpers.evalOk(id,
        \\const keys = Object.keys(ho);
        \\if (keys.length !== 2) throw new Error("keys " + keys.length + " " + keys.join(","));
        \\const keySet = new Set(keys);
        \\if (!keySet.has("prop1") || !keySet.has("prop2")) throw new Error(keys.join(","));
        \\const names = Object.getOwnPropertyNames(ho);
        \\if (names.length !== 2) throw new Error("names " + names.length + " " + names.join(","));
        \\const nameSet = new Set(names);
        \\if (!nameSet.has("prop1") || !nameSet.has("prop2")) throw new Error(names.join(","));
        \\if (!("missing" in ho)) throw new Error("in");
        \\if (!Object.prototype.hasOwnProperty.call(ho, "missing")) throw new Error("has");
        \\if (ho.missing !== undefined) throw new Error("get missing");
    );
    try testing.expectEqual(id, bag.id);
}

const FinFlag = struct {
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn countFin(user_data: ?*anyopaque) void {
    const flag: *FinFlag = @ptrCast(@alignCast(user_data orelse return));
    _ = flag.hits.fetchAdd(1, .seq_cst);
}

test "host object: finalizer runs once and does not call the engine" {
    var flag = FinFlag{};
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;

    try install(id, @ptrCast(&flag), .{ .finalize = countFin });
    try testing.expectEqual(@as(u32, 0), flag.hits.load(.seq_cst));

    engine.destroy(id);
    try testing.expectEqual(@as(u32, 1), flag.hits.load(.seq_cst));
}

const indexed_names = [_][]const u8{ "prop1", "1", "2", "prop2", "3" };

fn listIndexed(_: i32, _: ?*anyopaque, out_names: *[]const []const u8) void {
    out_names.* = indexed_names[0..];
}

test "host object: getOwnPropertyNames lists integer indices first" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try install(id, null, .{ .get_property_names = listIndexed });
    try helpers.expectEvalEquals(id, "Object.getOwnPropertyNames(ho).join(',')", "1,2,3,prop1,prop2");
}
