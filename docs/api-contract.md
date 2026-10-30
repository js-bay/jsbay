# Public API contract

This document defines the shared behavior of `include/jsbay.h` and the Android, Apple, .NET, and Harmony bindings. Function declarations are authoritative for names and fields; this document defines ownership, thread affinity, errors, and backend-independent meaning.

## Instances and threads

The host supplies an `int32_t` instance ID, including zero or negative IDs. It must be unique while an engine is alive. Creation returns `false` for any failure and does not classify that failure. The creating thread is the owner. Every engine and value operation, including loop attachment, release, and inspector, runs synchronously on that thread unless this document explicitly says otherwise.

`jsbay_engine_request_interrupt` and `jsbay_engine_stop_loop` are cross-thread and do not wait. `clear_interrupt` remains owner-thread-only. `jsbay_engine_destroy` is thread-safe and idempotent: off the owner it joins teardown (including waking a blocking `run_loop`). Prefer releasing every owned value on the owner thread, then destroying there; a foreign-thread destroy is for control paths such as destroy-then-`Worker.terminate`. Destroy closes the instance to public work immediately, but physical teardown can wait for the active JavaScript or native callback to return. Reusing an ID never revives a prior value.

Language bindings must provide explicit close or dispose operations (prefer the owner thread). Garbage-collector finalizers must not call engine destroy or value release.

## Build identity

`jsbay_engine_version` is process-wide and thread-safe; it does not require an instance or the owner thread. Callers set `struct_size` to at least `sizeof(jsbay_engine_version_info_t)`. On success the `version`, `commit`, and `backend` pointers are library-owned NUL-terminated strings that outlive any instance and must not be freed. `commit` may be empty when the build did not record a revision. `backend` is one of `quickjs_ng`, `quickjs`, or `jsc` (pack primary when built with `-Dbackends=`).

Library identity (no instance): `jsbay_library_backend` and `jsbay_library_capabilities` report the pack primary (`-Dbackends=` first entry, or `-Dbackend=`) and capability bits aligned with [embedding.md](embedding.md). `jsbay_available_backends` lists every packed engine in the artifact. Create-time select is `jsbay_engine_create_with_options` (not a live hot-switch of an existing instance).

For a pauseable Debugger embed template, host shutdown order, and version pinning when linking `libjsbay.a`, see [embedding.md](embedding.md).

## Status, exceptions, and outputs

Every status-returning operation with `out_value` and `out_exception` follows this matrix.

| Status | `out_value` | `out_exception` |
| --- | --- | --- |
| `JSBAY_OK` | A caller-owned nonzero value | Zero |
| `JSBAY_EXCEPTION` | Zero | A caller-owned nonzero thrown value |
| Any other status | Zero | Zero |

An exception is the original JavaScript value and may not be an `Error`. All outputs are initialized before the call. Bindings must preserve distinct non-OK statuses, especially wrong-thread, stale-value, and unsupported-feature results.

`jsbay_utf8_t` is length-delimited UTF-8 and may contain NUL in content values. `{ NULL, 0 }` is an empty string; a null data pointer with a nonzero length is invalid. Inputs that become names or paths reject embedded NUL. A returned `jsbay_bytes_t` is library-owned and must be freed by `jsbay_free_bytes` **exactly once**; bindings should copy it before exposing it to their language runtime. Calling `jsbay_free_bytes` twice on the same bytes (or freeing bytes the library did not return) is undefined and typically aborts the process (glibc double-free / AddressSanitizer). The API does not scrub the caller's `jsbay_bytes_t` after free.

## Value ownership

`jsbay_value_t` is an opaque, nonzero handle. A successful value-producing operation transfers one caller-owned reference. Each such reference must be released once. `retain` creates another owned reference. Values are scoped to one engine; foreign, released, destroyed, and pre-reuse handles are stale.

Callback `this` and argument values are borrowed for the duration of the callback only. They must not be released, and must not be used after the callback returns, unless first upgraded with `jsbay_value_retain` (or an SDK retain/reference helper): retain duplicates the backend value into a new caller-owned handle that outlives the callback. Releasing a borrowed handle fails without freeing the VM's stack value. A callback returns either one owned result, one owned exception, or neither; the engine consumes the transferred reference.

For C callbacks, `JSBAY_OK` requires an owned result and no exception; `JSBAY_EXCEPTION` requires an owned exception and no result; other statuses require both outputs to be zero. Return JavaScript `undefined` through an explicit value handle, not zero. Invalid output combinations do not transfer ownership: the engine must not guess which handles it can release.

SDK callbacks add a scope around this C contract. Borrowed argument wrappers expire at callback exit. Newly created owned values are also closed at scope exit unless explicitly retained for use outside the callback. The SDK retains a separate reference when transferring a return value or exception to the engine, so returning an argument is supported. Keeping a wrapper in an application variable does not extend its lifetime; retain it explicitly to escape the scope.

A successful native binding transfers its `user_data` to the engine until actual instance teardown, after active JavaScript and native callbacks have unwound. Rebinding the same name or collecting the JavaScript function does not run its finalizer early. The finalizer runs once on the owner thread; a failed bind does not transfer ownership or call it. Finalizers may release host resources but must not call engine or value APIs. Destroy the engine while the language runtime owning those resources is still alive.

## Evaluation, values, and modules

Evaluation is synchronous and produces either a live value or an owned thrown value. It is a microtask checkpoint: pending jobs run after the main operation, but a job failure does not replace the main result. If destruction starts during that checkpoint, no saved value is published.

Value property operations follow JavaScript semantics and report JavaScript throws through `out_exception`. `type` is an inspection operation and does not execute user JavaScript. `to_json` produces JSON text, not a generic string conversion: top-level undefined, functions, and symbols are invalid inputs.

`construct`, `has`, `delete`, `keys` and `instance_of` mirror `new`, `in`, sloppy-mode `delete`, `Object.keys` and `instanceof`, and they can run user JavaScript (getters, Proxy traps, `Symbol.hasInstance`). A thrown value comes back through `out_exception`. `has` throws a TypeError for a non-object. `delete` and `keys` convert a primitive with `ToObject` and throw a TypeError for `undefined` and `null`. `delete` reports `false` for a non-configurable property instead of throwing. `keys` returns a new array of own enumerable string keys (Proxy: `ownKeys` order, otherwise integer keys ascending, then creation order), and never runs `Array.prototype` setters. `instance_of` throws a TypeError when the constructor is neither callable nor has `Symbol.hasInstance`. Keys follow the same UTF-8 and no-embedded-NUL rule as `get` and `set`. On QuickJS an internal allocation failure inside these calls may surface as an exception instead of `JSBAY_OUT_OF_MEMORY`.

`EngineConfig.module_loader` belongs to the engine lifetime. The host owns source storage returned by `load` and must keep it valid after the callback returns; loader-owned storage that lasts for the engine lifetime is the safe default. QuickJS uses resolve and load callbacks. On supported Apple platforms, JSC uses a private Objective-C bridge; verify module behavior on the deployment target.

## Timers, cache, and limits

The JavaScript event loop owns its monotonic clock, timers, waiting, and wakeups. Call `jsbay_engine_run_loop` on a dedicated owner thread, or let the SDK connect it to the platform owner thread. Calling it from a synchronous native callback, queued task, or microtask returns `JSBAY_INVALID_ARGUMENT`, so the current JavaScript turn can finish. `jsbay_engine_stop_loop` is thread-safe. When no run is active it applies to the next `jsbay_engine_run_loop`, which consumes it, and attaching a platform loop discards a request made before it. While a platform loop is attached it stops that loop's driving until detach and a later attach. Each queued JavaScript task finishes with a microtask checkpoint; callers do not supply timestamps or compute deadlines.

`jsbay_engine_suspend` / `jsbay_engine_resume` / `jsbay_engine_is_suspended` are thread-safe keep-alive controls. Suspend is orthogonal to attach: it keeps the VM and Host binding, cancels only a pending platform schedule, and blocks new turns until resume. It is not `stop_loop` (exit a blocking run), not `detach_loop` (drop the Host), and not `destroy`. Resume must not drop registered timers or queued tasks; overdue work catches up on real monotonic time after Show.

`jsbay_engine_list` and `jsbay_engine_snapshot` are thread-safe observability pulls. Snapshot `struct_size` must be `sizeof(jsbay_instance_snapshot_t)`. Missing or teardown-pending instances return false from snapshot; list omits teardown-pending ids. Snapshot `flags` bit2 is reserved/unused (teardown is not reported as a flag).

Persistent bytecode cache is optional and only active when both cache directory and version are supplied. Cache read, write, and compile failures fall back to one source execution; a cache failure must not run source twice. A cache hit means executable cached bytes were used, even if that code throws.

Execution and memory limits are controls, not a process sandbox. Per-instance native admission budgets are set with `jsbay_engine_create_with_limits` / `jsbay_engine_set_resource_limits` and inspected with `jsbay_engine_get_resource_usage` and `jsbay_resource_global_usage`; process-wide caps remain shared and nonblocking within an admission class, with a 25% foreground headroom. See [runtime-limits.md](runtime-limits.md) and [backend selection](embedding.md#backend-selection).
Execution and memory limits are controls, not a process sandbox. See [runtime-limits.md](runtime-limits.md), [host-isolation.md](host-isolation.md), and [backend selection](embedding.md#backend-selection).

Owner-thread observability: `jsbay_engine_get_memory_usage`, `jsbay_engine_run_gc`, and `jsbay_engine_set_event_handler` (telemetry kinds for log / interrupt / memory limit / loop failed). The create-time `jsbay_log_handler_t` remains the console sink. Event handlers must not call engine or value APIs.

## Synchronous native extension

`jsbay_engine_bind_sync` and `jsbay_sync_complete` are optional. Only completion is cross-thread; it requires a payload kind and copied bytes (`UTF8_STRING` / `BYTES` primary, `JSON` explicit opt-in) rather than a live JavaScript value. Its timeout, cancellation, and queue requirements are specified in [native-sync.md](native-sync.md).
