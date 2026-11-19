# HyperBox

HyperBox is a standalone value representation and generational handle indexing library written in Zig.

It is designed for dynamic language runtimes and FFI bridges that require zero-allocation primitive representation, fast type queries, and safe handle lifecycles.

## Core Responsibilities

HyperBox focuses strictly on value encoding and handle storage:

- **64-bit NaN Boxing (`Value`)**: Encodes doubles, 32-bit signed integers, booleans, null, undefined, empty sentinels, and engine handles into a single 64-bit word using the upper quiet-NaN space (`0xFFF8_0000_0000_0000` to `0xFFFF_FFFF_FFFF_FFFF`).
- **Small String Optimization (SSO)**: Packs UTF-8 strings up to 6 bytes directly into the 48-bit NaN payload with zero heap allocations, enabling single-instruction register comparisons (`ssoEquals`).
- **Generational Handle Map (`GenerationalSlotMap`)**: Provides O(1) handle lookups with 16-bit generation counters for ABA defense. Tracks instance handles via intrusive doubly-linked slot lists for allocation-free bulk teardown (`detachFirstForInstance`).
- **32-Bit Target Support (`SplitBox32`)**: Provides a 64-bit pair layout that maps directly to 32-bit calling conventions (such as ARM AAPCS) without altering 64-bit semantics.

## Out of Scope

HyperBox intentionally excludes application-level concerns:

- It does not contain string hashing, string dictionaries, or protocol atom dispatchers.
- It does not contain event routing, bit-matrices, or scheduler tasks.
- It has no dependencies on JavaScriptCore, QuickJS, Hermes, or any host bridge protocols.

## Memory and Safety Invariants

- **IEEE-754 Safety**: All floating-point doubles, negative zero (`-0.0`), infinities, and subnormals remain distinct from tagged values. Hardware signaling NaNs are canonicalized in the integer domain to prevent CPU traps.
- **Strict Deallocation Discipline**: `GenerationalSlotMap.remove` and instance teardown never allocate memory and cannot fail.
- **Zero Allocations for Primitives**: Int32, booleans, floats, null, undefined, and SSO strings up to 6 bytes never touch the heap or take mutex locks.

## Usage

```zig
const std = @import("std");
const hyper_box = @import("hyper_box");
const Value = hyper_box.Value;
const GenerationalSlotMap = hyper_box.GenerationalSlotMap;

// Box and unbox primitives in registers
const num = Value.fromInt32(42);
const sso = Value.fromSso("status").?;

// Query types without branching cascades
if (sso.isSso()) {
    var buf: [6]u8 = undefined;
    const len = sso.copySso(&buf);
    _ = buf[0..len];
}

// Manage live engine handles safely
var slot_map = GenerationalSlotMap.init(std.testing.allocator);
defer slot_map.deinit();

const handle = try slot_map.allocateSlot(1, 0xCAFE);
if (slot_map.get(handle)) |payload| {
    _ = payload;
}
slot_map.remove(handle);
```

## Testing

Run the package test suite:

```sh
zig build test
```
