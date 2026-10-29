# js_event_loop

JavaScript scheduling built on `zev`. The package depends on `zev` and the Zig standard library; it contains no JavaScript engine or host API bindings.

`Driver` owns the native `zev` loop, its monotonic clock, waiting, timers, notifications, and browser-style turns. `run` and `runFor` drive an environment on a dedicated thread without a host clock or deadline. `attach` drives an environment on a platform-owned thread. Callers do not pump turns, sample clocks, or calculate deadlines.

`attach` connects a Driver to a platform-owned thread. The platform supplies a coalescing asynchronous `Host.schedule` callback and a matching owner-thread `Host.cancel`; it invokes the supplied drive callback, which calls `runAttached` while the engine lease is held. A Driver schedules its own next callback after each turn, wakes early when a timer or notification changes, and does not poll while idle. `detach` runs on the owner thread before the runtime is released. Blocking `run` and attached driving are mutually exclusive. `requestStop` ends the active blocking run; when none is active it applies to the next run, and the run that ends consumes it; `attach` discards a request made before it. While attached it stops platform driving until `detach` and a later `attach`, and `detach` discards the request.

`Timer` and `Notifier` are Driver-owned wrappers around native handles. Callers initialize them with a Driver, schedule absolute monotonic times or relative delays, notify from another thread, and never access `zev.Loop` directly.

`Scheduler` owns task admission, synchronous execution and native-wait scopes, non-reentrant microtask checkpoints, and the order of a driver-owned turn. Each host task, native dispatch callback, TSFN callback and JS timer callback finishes before its microtask checkpoint. Microtasks added by microtasks drain before another queued task starts.

A synchronous native call holds `SyncWait` from its host start callback until its result or exception is returned. Other threads may enqueue work and complete the request, but this environment cannot run queued JavaScript or microtasks during that wait. `native_sync` delivers bytes directly to the waiting thread through `zev.Condition`; it never needs a JavaScript task to deliver a result.

One owner thread calls `start`, uses its returned request pointer, then calls `wait` and `finish` in order. It may read returned bytes until `finish`, which must run once after that read. A reduced deadline can turn an already completed result into a timeout before `wait` delivers it; after `wait` returns, later deadline changes leave that result and its borrowed bytes unchanged. Completion, cancellation, and instance-wide cancellation or deadline changes may run concurrently.

`host_wake` is an internal bridge for components that need to wake a Driver. Applications use `Driver.run`, `Driver.runFor`, or `Driver.attach`; they do not register wake callbacks or pump turns themselves. `set` and `drop` may run concurrently, including for one instance ID. After active callbacks finish, their effects for that ID follow the order in which they reacquire the slot mutex. Neither may run from a host-wake callback.

The host supplies the actual JavaScript calls, exception handling and job-drain operation. Every scope must finish while its runtime remains alive. Scheduler state is owner-thread only; native completion and notification registries have their own synchronization. The root engine owns runtime admission and destruction and keeps JS values in its timer/dispatch adapters. `zev` remains the sole owner of the native timer heap.

Each turn first collects native readiness, then starts at most one ready JavaScript task and performs a complete microtask checkpoint. The scheduler rotates fairly among host scripts, native dispatch callbacks, TSFN payloads and due timers. Tasks from one source keep FIFO order. Ordering between sources is intentionally unspecified. A future host `nextTick` binding belongs to the embedder and must enqueue a later task, rather than a Promise microtask or Node.js `process.nextTick`. This package does not claim complete HTML or Node.js event-loop compatibility.

JavaScriptCore runs Promise reactions inside its VM; QuickJS-family backends expose an explicit job drain. The engine adapter enforces its controllable task and checkpoint boundaries and tests the observable contract on all three backends.

Run `zig build test` in this directory. Pure scheduling, native wait and notification contracts live here; real-engine ordering and lifecycle tests live in the root suite. Root `zig build test` also runs this suite and forwards `-Dtest-filter`.
