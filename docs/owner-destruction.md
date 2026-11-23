# Owner-affine destruction

## Compatibility and adoption

`JSBAY_DESTROY_PROTOCOL_VERSION` and `jsbay_engine_destroy_protocol_version()` identify protocol version 2. This is an additive C ABI and Zig core capability, not a claim that every language binding exposes it. Hosts must deploy a matching library and header, check the runtime version, and adapt their owner event dispatcher before using foreign destruction. The creating thread remains the owner; no worker is created and no synchronous dispatch to the owner is introduced. Callback scheduling and normal reentry rules do not change.

The legacy `jsbay_engine_destroy` remains an owner-thread convenience. Its unversioned foreign teardown cannot guarantee owner-affine finalizers and is unsupported. Never race legacy teardown with the initial versioned request; `ALREADY_CLOSING` reports a legacy close already in progress and does not convert it into the new protocol. After a versioned request, foreign legacy calls cannot take over teardown, while creator legacy calls attempt a drain. A void return is not proof of completion.

## Protocol

1. On the creator, create the engine, take `jsbay_engine_snapshot`, and retain its nonzero `generation` together with the ID before closing. A token must be captured from a real live instance, not fabricated.
2. From any thread, call `jsbay_engine_request_destroy(id, generation)`. The first request atomically closes admission, stops and wakes the native loop, cancels synchronous native waits, abandons debugger pauses, and requests a cooperative interrupt. It does not run finalizers or free the VM, allocate a teardown task, synchronously dispatch to the owner, or wait for the owner to pump. Concurrent duplicates coalesce. New public engine/value entries return their existing closed-instance error; outputs retain their normal clearing rules.
3. Arrange an asynchronous host task on the original creator, independently of the now-closed engine submission queue. Call `jsbay_engine_drain_destroy` outside engine entries, callbacks, dispatch tasks, and held control leases. Do not spin or wait for completion from a callback. A pending drain must be retried after unwinding or after foreign control operations finish.
4. `COMPLETE` means that generation is no longer registered after its finalizers and backend context/runtime frees have returned. It is not an allocator byte-count guarantee, an OS-thread-exit signal, or permission to release a host loop binding before its own detach contract is satisfied. Retain host callback state until completion and separately confirm platform loop/environment shutdown.

| Result | Meaning |
| --- | --- |
| `LIVE` | No versioned request is pending; drain does not initiate one. |
| `PENDING` | Teardown is requested or executing; resources and callback state remain owned by the live generation. |
| `COMPLETE` | The valid captured generation is absent; query also returns this after ID replacement. |
| `INVALID_ARGUMENT` | Generation is zero. |
| `WRONG_THREAD` | A live generation was drained from a thread other than its creator. |
| `STALE` | Request or drain targeted a different live generation; that replacement is untouched. |
| `ALREADY_CLOSING` | Legacy teardown is already in progress; the request was not adopted. |

Request and status are any-thread operations. Drain is creator-only while the generation exists. The creator identity includes a thread-local incarnation as well as the native thread ID, so a later thread reusing that ID cannot take ownership. Request may return a pending snapshot even if another thread subsequently observes completion. Every finalizer runs exactly once on the creator during an accepted drain. A finalizer may call only these destruction controls: status and duplicate request observe pending, and reentrant drain returns pending without recursive release. This narrow exception does not authorize other engine/value APIs from finalizers.

A creator blocked joining the requesting thread does not deadlock: the request returns without waiting for that creator, which can drain after joining. An arbitrary native callback cannot be preempted. An unpumped or exited creator does not become complete, and no foreign rescue frees its VM. Hosts must drain before allowing the creator or its language runtime to exit; otherwise the generation remains pending and its ID stays reserved. Polling is not a replacement for an owner dispatcher. An unannounced thread exit provides no resource-reclamation guarantee.

## C host sequence

```c
jsbay_instance_snapshot_t snapshot = {.struct_size = sizeof(snapshot)};
if (!jsbay_engine_snapshot(id, &snapshot)) {
    /* Handle a missing instance before publishing a token. */
    return;
}
uint64_t generation = snapshot.generation;
/* Publish the id/generation pair to the control thread with host synchronization. */
/* Control thread: request, then enqueue a host-owned asynchronous creator task. */
jsbay_destroy_status_t requested = jsbay_engine_request_destroy(id, generation);
/* Creator task, after all engine callbacks return: */
if (requested == JSBAY_DESTROY_PENDING) {
    jsbay_destroy_status_t drained = jsbay_engine_drain_destroy(id, generation);
    /* Retain callback state and retry on a later host turn if still PENDING. */
    (void)drained;
}
```

The comments describe distinct host turns, not permission to run the creator task on the control thread. The Zig equivalents are `engine.requestDestroy`, `engine.drainDestroy`, and `engine.destroyProgress`, with typed progress and errors. Neither API implicitly releases host-language wrappers.

## Binding and release boundary

The Android JNI/Kotlin and Java SDK now expose this protocol as `Engine.requestClose`, `closeStatus`, and creator-only `drainClose`. JNI refuses a mismatched destruction protocol at load, retains matching-generation hooks until completion, and uses creator-checked opaque monotonic loop handles instead of exposing recyclable pointers. Apple, .NET, Harmony, and Node.js wrappers still require explicit adaptation before exposing versioned foreign close. Keep pending distinct from closed; retain generation-tagged JNI/global callback hooks until matching completion; never clear a replacement generation's hooks; schedule drains on the original creator outside engine work; and keep environment teardown alive until draining finishes. Other SDK `close`/dispose implementations are not automatically upgraded by these core symbols. ABI consumers, AAR/Maven packaging, R8, release builds, and Inspector need certification against the changed production core rather than inheriting certification from an older core.

## Android lifecycle migration

Deploy the new Kotlin/Java classes, JNI adapter, and protocol-v2 core together; mixed artifacts are unsupported. This lifecycle migration must ship under a new major SDK version, not replace an existing released artifact: `DedicatedEngineThread.close()` now requests asynchronously instead of synchronously dispatching and joining. No release version is selected or published by this local change. `Engine.close()` remains owner-only; it requests and attempts one drain, and its void return is not completion evidence, especially inside callbacks. Do not use foreign `Native.destroy` as an alternative.

`requestClose()` closes wrapper admission immediately; retained `Value`s can no longer be used. This is separate from physical release. `closeStatus()` is any-thread, data-only VM progress. `drainClose()` must run on the original Java creator thread after callbacks unwind; `COMPLETE` means native teardown ended and that drain released the matching JNI state. Data-only status does not acknowledge completion of JNI hook cleanup or prove the host Looper thread has terminated. Before stopping the host language runtime, obtain an acknowledgement after owner `drainClose()` returns complete, not merely a successful data-only poll. Duplicate requests coalesce and a stale generation cannot destroy or clear a replacement.

```kotlin
// Creator without a Looper: retain engine until this owner-side drain completes.
val engine = Engine(42)
val requester = Thread { check(engine.requestClose() == CloseStatus.PENDING) }
requester.start()
requester.join() // Safe: requester does not synchronously dispatch back here.
check(engine.drainClose() == CloseStatus.COMPLETE) // Outside engine callbacks/work.
```

```java
// Same manual-owner migration in Java.
Engine engine = new Engine(43);
Thread requester = new Thread(() -> engine.requestClose());
requester.start();
requester.join();
if (engine.drainClose() != CloseStatus.COMPLETE) {
    // Keep the original creator alive; retry on a later host turn after leases end.
}
```

For an existing Android Looper creator, each request coalesces one independent `Handler` drain task, not an engine-queue task. It does not install a new owner thread. If the task still finds a lease or callback, progress remains pending: arrange another later owner `drainClose()` or call `requestClose()` again to schedule another attempt. There is no busy wait, hidden timeout, unbounded timer retry, or synchronous owner dispatch. Check progress before quitting the Looper. The existing opt-in `DedicatedEngineThread` helper similarly posts a nonblocking completion attempt and only quits after creator drain completes; retry its request if a lease deferred that attempt. Its `runOnOwner` remains a synchronous general-work helper and must not be used to wait on teardown while the creator joins the caller.

A rejected post, stopped/unpumped Looper, or exited creator leaves `PENDING`, with wrappers/native resources retained. No foreign fallback frees the VM or invokes finalizers. Resuming the same creator and draining is the only in-process recovery; an exited creator cannot be replaced by a new thread with a recycled OS id. Keep host/process teardown alive until completion, or explicitly accept process-lifetime retention. This preserves creator-is-owner and existing callback/reentry semantics rather than silently moving ownership.

The standalone Android diagnostic runs real ART and measures returned backend context/runtime free calls separately from exactly-once finalizer count/thread. It is not a retained-byte or sanitizer certificate. Fault-only counters and probe exports are absent from normal packaged builds.
