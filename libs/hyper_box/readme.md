# HyperBox

HyperBox is a hardware-sympathetic value engine implemented in Zig.

## Features

- IEEE-754 negative quiet-NaN 64-bit value boxing with branchless type predicates.
- Inline short-string optimization (SSO) encoding 0 to 6 bytes directly in NaN payload space.
- Generational slot indexing with 16-bit generation counter for O(1) ABA validation and instant teardown.
- Dual-track 32-bit register split compatibility for resource-constrained architectures.
- Zero allocation for primitive types and immediate string keys.
