# js-bay .NET SDK

`JsBay.Engine` is a thin .NET binding for the stable daily C API in `include/jsbay.h`. It does not create an engine thread, queue work, or provide a module loader. Create it on the thread that will run JavaScript, then call `Dispose` on that same thread.

```csharp
using JsBay;

using var engine = new Engine(42);
using var value = engine.Evaluate("6 * 7", "main.js");
Console.WriteLine(value.Number());
```

`Value` owns one native reference and implements `IDisposable`. Values passed to a `Bind` callback are borrowed: they cannot be disposed or kept after the callback returns. Use `Retain()` inside the callback when a value must escape. A JavaScript throw becomes `JsException`; its `Value` is the original thrown value and must also be disposed.

When only display text is needed, `JsException.DescribeAndClose()` reads and consumes that original value. It keeps embedded NUL and Unicode, and returns `"JavaScript exception"` after a second JavaScript throw from coercion while closing both values. `TryDescribe()` remains non-consuming for callers that retain the original value. Wrong-thread, borrowed, and stale-value failures are still reported as `JsBayException`.

```csharp
try
{
    using var result = engine.Evaluate("throw new Error('example')");
}
catch (JsException error)
{
    Console.Error.WriteLine(error.DescribeAndClose());
}
```

Values created inside a callback are released automatically when the callback ends. Return one directly; do not dispose it before returning.

`BindSync` is for a system request that must look synchronous to JavaScript while its work completes on another thread. Its starter receives borrowed `SyncCall` values and a thread-safe `SyncCompletion`; schedule the native work, return immediately, then call `ResolveString`, `ResolveBytes`, or `Reject` once. The completion token accepts only copied bytes and has no `Value`, so it is safe to pass to a thread-pool task. It is intentionally unsuitable for work that needs the owner thread's event loop to make progress.

Owner-thread observability: `GetMemoryUsage()`, `RunGc()`, and `SetEventHandler`. `CreateOnBackground` is a thin `Task.Run` helper — prefer a dedicated owner thread with a real `SynchronizationContext` for production timers. Same-process native faults still kill the host; see `docs/host-isolation.md`.

Only `Engine.RequestInterrupt()` and `Engine.StopLoop()` are safe from a non-owner thread. `Dispose`, evaluation, conversion, binding, values, and inspector calls are owner-thread operations. Construction attaches the event loop only to a custom current `SynchronizationContext` whose `Post` implementation always dispatches asynchronously to the creating thread and remains available until `Dispose`; a rejected dispatch or a callback on another thread puts the loop into `LoopFailed`, which the creating thread observes on its next engine operation. A context that only inherits the base `SynchronizationContext.Post` implementation has no fixed owner thread, so use `RunLoop()` on the creating thread instead. The SDK does not declare finalizers because finalizer threads cannot satisfy that rule; use `using` or call `Dispose` explicitly.

The application supplies the platform-specific `jsbay` native library through the normal .NET native library search path. This package does not ship a Node/Electron adapter and does not select a runtime backend.

The repository consumer test is `tests/dotnet-sdk/run.sh quickjs_ng` or `tests/dotnet-sdk/run.sh jsc`. Set `DOTNET` when the SDK executable is outside `PATH`, and `JSBAY_DOTNET_ARTIFACTS` to choose the build-artifact directory. It builds the selected shared library and uses the platform native-library search path for that one process.

The managed quality checks use .NET SDK 8.0.426, pinned by the root `global.json`. Run `scripts/quality/dotnet-style.sh check` and `scripts/quality/dotnet-lint.sh check` from any directory; replace `check` with `fix` to apply available Roslyn fixes. Both commands cover the SDK and external consumer, including test-hook code. `self-test` checks each gate against a deliberately invalid temporary source and verifies that fixing twice leaves it unchanged. The lint gate also builds with recommended .NET 8 analyzers and treats warnings as errors, including rules without an automatic fix. Set `DOTNET` when the executable is outside `PATH`.
