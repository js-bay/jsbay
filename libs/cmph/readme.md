# CMPH (Comptime Minimal Perfect Hash)

A zero-allocation, branchless compile-time minimal perfect hash generator in Zig.

Given a static dictionary of string keys at compile time, `cmph` searches for a collision-free seed and bakes a compact O(1) lookup table directly into the binary. At runtime, resolving a string into an index takes integer hashing and a single array lookup without heap allocations.

## Features

- **Zero Collisions**: Guaranteed 1-to-1 mapping for all dictionary keys found at compile time.
- **Zero Allocations**: Evaluates entirely at compile time; runtime lookups require no dynamic memory.
- **Branchless Lookup**: Computes hash slot in integer arithmetic without strcmp cascades.
- **Compact Footprint**: Minimal table sizing fitting comfortably within L1 cache lines.

## Usage

```zig
const std = @import("std");
const cmph = @import("cmph");

const HTTP_METHODS = [_][]const u8{
    "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH",
};

const MethodMatcher = cmph.ComptimeMinimalPerfectHash(&HTTP_METHODS);

pub fn route(method: []const u8) ?usize {
    return MethodMatcher.match(method);
}
```

## Testing

```sh
zig build test
```
