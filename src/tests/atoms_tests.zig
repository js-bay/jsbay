//! Tests for the Atom API (src/value/atoms.zig).
//!
//! Atoms are pre-interned property keys that skip per-access string hashing. Both backends must pass. Tests cover:
//!   1. newAtom + atomToString roundtrip
//! 2. interning equivalence — same name decodes to same string on both backends (backend may or may not return identical repr)
//!   3. setProperty + getProperty roundtrip through an atom
//!   4. hasProperty truthiness for present vs absent keys
//!   5. atom-write / string-read interop (JS eval sees the value)
//!   6. freeAtom then newAtom again does not crash or corrupt state

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const atoms = @import("../value/atoms.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ---------------------------------------------------------------------------
// 1. newAtom + atomToString roundtrip
// ---------------------------------------------------------------------------

test "Atom: newAtom + atomToString roundtrip" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const atom = atoms.newAtom(id, "foo") orelse return error.NewAtomFailed;
            defer atoms.freeAtom(id, atom);

            const decoded = atoms.atomToString(testing.allocator, id, atom) orelse
                return error.DecodeFailed;
            defer testing.allocator.free(decoded);

            try testing.expectEqualStrings("foo", decoded);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 2. Two atoms interned from the same name decode to the same string.
//
// On QuickJS, JS_NewAtom collapses to the same JSAtom slot (so repr is identical). On JSC, each call may hand back a fresh JSStringRef, so we assert only the decoded-string equivalence.
// ---------------------------------------------------------------------------

test "Atom: two atoms for same name round-trip to equal strings" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const a1 = atoms.newAtom(id, "hotKey") orelse return error.A1;
            defer atoms.freeAtom(id, a1);
            const a2 = atoms.newAtom(id, "hotKey") orelse return error.A2;
            defer atoms.freeAtom(id, a2);

            const s1 = atoms.atomToString(testing.allocator, id, a1) orelse
                return error.Decode1;
            defer testing.allocator.free(s1);
            const s2 = atoms.atomToString(testing.allocator, id, a2) orelse
                return error.Decode2;
            defer testing.allocator.free(s2);

            try testing.expectEqualStrings(s1, s2);
            try testing.expectEqualStrings("hotKey", s1);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. setProperty + getProperty through an atom
// ---------------------------------------------------------------------------

test "Atom: setProperty then getProperty returns written value" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);

            const key = atoms.newAtom(id, "count") orelse return error.NewAtomFailed;
            defer atoms.freeAtom(id, key);

            const written = ActiveEngine.newInt32Val(ctx, 42);
            // setProperty consumes `written` on both backends — must NOT freeValue afterwards.
            try testing.expect(atoms.setProperty(id, obj, key, written));

            const read = atoms.getProperty(id, obj, key) orelse return error.Missing;
            defer ActiveEngine.freeValue(ctx, read);
            try testing.expectEqual(@as(?i32, 42), ActiveEngine.toInt32(ctx, read));
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. hasProperty behaves like JS `in` for set and unset keys
// ---------------------------------------------------------------------------

test "Atom: hasProperty true after set, false for absent" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);

            const present = atoms.newAtom(id, "present") orelse return error.NewPresent;
            defer atoms.freeAtom(id, present);
            const absent = atoms.newAtom(id, "absent") orelse return error.NewAbsent;
            defer atoms.freeAtom(id, absent);

            try testing.expect(!atoms.hasProperty(id, obj, present));
            try testing.expect(!atoms.hasProperty(id, obj, absent));

            const v = ActiveEngine.newInt32Val(ctx, 1);
            try testing.expect(atoms.setProperty(id, obj, present, v));

            try testing.expect(atoms.hasProperty(id, obj, present));
            try testing.expect(!atoms.hasProperty(id, obj, absent));
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 5. Atom-write + JS-read interop: a value stored via an atom key must be readable from JS under the same property name.
// ---------------------------------------------------------------------------

test "Atom: native atom write is visible to JS under the same key" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);

            const key = atoms.newAtom(id, "__atom_written__") orelse
                return error.NewAtomFailed;
            defer atoms.freeAtom(id, key);

            const marker = ActiveEngine.newInt32Val(ctx, 1337);
            try testing.expect(atoms.setProperty(id, global, key, marker));

            const out = try helpers.evalString(
                testing.allocator,
                id,
                "String(globalThis.__atom_written__)",
            );
            defer testing.allocator.free(out);
            try testing.expectEqualStrings("1337", out);

            // Conversely, a value assigned from JS should be readable via the atom — exercises the string→atom lookup path on both backends.
            try helpers.evalOk(id, "globalThis.__atom_written__ = 2024;");
            const read = atoms.getProperty(id, global, key) orelse return error.Missing;
            defer ActiveEngine.freeValue(ctx, read);
            try testing.expectEqual(@as(?i32, 2024), ActiveEngine.toInt32(ctx, read));

            // Cleanup so later tests don't see the leaked global.
            try helpers.evalOk(id, "delete globalThis.__atom_written__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 6. freeAtom followed by newAtom(same name) does not crash.
//
// This is the refcounting smoke test: on QuickJS freeing the last user of a JSAtom decrements but the table entry may be reused by the next NewAtom. On JSC the second newAtom allocates a fresh JSStringRef. In both cases the roundtrip must keep working.
// ---------------------------------------------------------------------------

test "Atom: freeAtom then re-intern is safe" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const first = atoms.newAtom(id, "reusable") orelse return error.First;
            atoms.freeAtom(id, first);

            const second = atoms.newAtom(id, "reusable") orelse return error.Second;
            defer atoms.freeAtom(id, second);

            const decoded = atoms.atomToString(testing.allocator, id, second) orelse
                return error.DecodeFailed;
            defer testing.allocator.free(decoded);
            try testing.expectEqualStrings("reusable", decoded);
        }
    }.run);
}
