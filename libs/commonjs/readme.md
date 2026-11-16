# commonjs

An engine-independent local Zig package for CommonJS loading transactions and instance caching. Version 0.1.0; Zig 0.17.0 or newer. It has no dependencies, VM headers, engine root directory, native bridge, or network requirement. It is a repository-local package, not an external registry release.

```sh
cd libs/commonjs
zig build test -Dtarget=x86_64-linux-gnu --summary all  # Linux x86-64
zig build test -Dtarget=native --summary all            # current host
zig build test-fmt
```

The exported build module is `commonjs`. A consuming `build.zig.zon` may declare `.commonjs = .{ .path = "path/to/commonjs" }`; import `b.dependency("commonjs", .{ .target = target, .optimize = optimize }).module("commonjs")` under that name. The package can be copied alone (LICENSE, readme, build files and src) to another directory and tested there.

## Boundary

The package owns canonical-ID copying/interning, loader-result release, loading transactions, cycle lookups, completed instance entries, cache-reference retention/release, retry rollback, and reentrant clear/reload generation checks. It does not own parsing or execution, bytecode/persistent-cache policy, JS exceptions, global/native function registration, thread admission, schedulers, or teardown timing. No generic Host object grants access to an engine or backend.

`Loader`, `LoaderVTable` and `LoadResult` are a narrow synchronous C-shaped callback contract, independent of any embedding runtime's public loader structs:

- `resolve(user_data, referrer_z, specifier_z)` is optional. A null result uses the specifier unchanged. A non-null result is copied, then `free_resolved` is called exactly once if provided, including when the copy fails. A null release callback means the host keeps ownership (e.g. static output).
- `load(user_data, canonical_id_z, out)` returns false for a missing module, or supplies borrowed source bytes and their length. Bytes must remain valid after the callback returns until the package copies them. Do not return stack storage. No source-release callback is implied.
- Callback input strings are borrowed only during the callback. The loader/vtable itself is borrowed only during the synchronous `require` transaction.
- `loadSource` returns OutOfMemory for allocation failure and null only for a loader miss. Registry require preserves that distinction instead of reporting a missing module on a copy-allocation failure.
- Canonicalization and filesystem/path policy belong to the loader; `dirnameOf` only finds the last slash/backslash. The caller supplies the actual module referrer or its chosen root fallback.

`Registry(Ops)` takes only typed reference/environment operations:

```zig
pub const Context = /* host's execution context */;
pub const Value = /* host's typed VM handle, not serialized JSON */;
pub fn newExports(ctx: Context) error{OutOfMemory}!Value;
pub fn newModule(ctx: Context, initial_exports: Value) error{OutOfMemory}!Value;
pub fn readExports(ctx: Context, module: Value) error{CallFailed}!Value;
pub fn retain(ctx: Context, value: Value) Value;
pub fn release(ctx: Context, value: Value) void;
```

Constructors return owned values or `error.OutOfMemory`; a failed constructor releases its partial environment and must never return a VM error sentinel. Constructors and loader callbacks may perform bounded nested requires: after each callback the registry adopts an entry installed by that nested call rather than evaluating or overwriting it again. Recursive initialization must eventually terminate; there is no live partial module until `newModule` returns. `retain` and `release` must not reenter the registry. Engine adapters must define the initial `exports` as an own data property without invoking user prototype setters. `newModule` creates a module with the supplied initial exports and retains its own reference to those exports. `readExports` returns an owned value, including a real undefined value when supported by the host; it reports accessor failure separately. `retain` returns an additional owned reference, and `release` consumes one. Values passed into these operations are otherwise borrowed. The host must supply valid environment values using its own allocation/exception conventions; the package does not inspect engine-specific error sentinels.

`require(ctx, source_allocator, loader, execute, specifier, referrer)` owns the loading transaction. `execute` has the signature:

```zig
fn (Context, std.mem.Allocator, []const u8, []const u8, []const u8,
    Value, Value) ExecutionError!Value
// ctx, execution allocator, source, canonical filename, dirname,
// initial exports, live module -> owned final exports
```

It must use the supplied initial exports/module environment; creating a detached exports object would break cycles. Source, IDs, dirname and the environment are borrowed during the call. Retained require functions must copy/capture their own module referrer, never keep a borrowed ID slice. `ExecutionError` is OutOfMemory/Compile/CallFailed; the require layer maps Compile to CompileFailed. JS exception transport stays with the host.

## Cache and ownership semantics

A loading entry holds the live module object. Cycles therefore see the same initial exports object and its subsequent field mutations; after reassignment, later cycle lookups see the current module.exports without rewriting earlier aliases. A completed entry retains the final value, including undefined. It is a completed-value snapshot, not a post-completion retained-module mutation tracker.

Failures remove only their own transaction, allowing retry. A generation guard prevents an older success/failure from replacing/removing a newer entry installed after a reentrant clear and same-ID reload. `clear(ctx)` releases cache references immediately while in-flight keys/environments stay alive. If no newer entry exists, a successful in-flight transaction may recache its final result after clear. This is not a dependency-graph invalidator.

The host serializes operations on its owning VM thread and must not deinitialize/uninstall during an active transaction. At an idle teardown point call `clear(ctx)` and then `deinitStorage()`; the host chooses that point. Each returned require value is caller-owned even if the cache is subsequently cleared. Compile/bytecode caches are separate and are never cleared here.

The tests use typed reference-counted fake values, not a fake VM, and cover canonical-result release (including allocation failures), copying, live cycle aliases, rollback, generation ownership, reentrant clear, and balanced references across registry allocation failures. Runtime exception behavior and backend-specific undefined semantics must be tested by the embedding host.
