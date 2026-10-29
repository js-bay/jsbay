//! Symbol identity. Unique symbols with the same description are not ===. Registry symbols match `Symbol.for`.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const symbol = @import("../value/symbol.zig");
const value = @import("../value/root.zig");

const ActiveEngine = backend.ActiveEngine;

test "symbol: newSymbol with the same description is not strict-equal" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    const ctx = engine.getContext(id).?;
    const a = symbol.newSymbol(id, "same") orelse return error.SymbolFailed;
    defer ActiveEngine.freeValue(ctx, a);
    const b = symbol.newSymbol(id, "same") orelse return error.SymbolFailed;
    defer ActiveEngine.freeValue(ctx, b);

    try testing.expect(!value.strictEquals(id, a, b));

    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, "a", ActiveEngine.dupValue(ctx, a));
    ActiveEngine.setPropertyStr(ctx, global, "b", ActiveEngine.dupValue(ctx, b));
    try helpers.evalOk(id, "if (a === b) throw new Error('equal'); if (a.description !== 'same' || b.description !== 'same') throw new Error(String(a.description));");
}

test "symbol: forKey matches Symbol.for" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    const ctx = engine.getContext(id).?;
    const s = symbol.forKey(id, "shared") orelse return error.SymbolFailed;
    defer ActiveEngine.freeValue(ctx, s);
    const again = symbol.forKey(id, "shared") orelse return error.SymbolFailed;
    defer ActiveEngine.freeValue(ctx, again);
    try testing.expect(value.strictEquals(id, s, again));

    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, "s", ActiveEngine.dupValue(ctx, s));
    try helpers.evalOk(id, "if (s !== Symbol.for('shared')) throw new Error('registry'); if (s.description !== 'shared') throw new Error(String(s.description));");
}
