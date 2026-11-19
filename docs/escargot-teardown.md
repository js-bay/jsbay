# Escargot teardown ownership

## Public contract

`include/jsbay.h` permits thread-safe foreign-thread destroy and requires it to join teardown. `docs/api-contract.md` also requires native binding finalizers to run on the owner thread. Owner-thread destroy after releasing values remains the recommended shutdown sequence, not a replacement for those foreign-thread guarantees.

## Current owner protocol

`instance_map.markTeardownPending` closes admission under the registry and dispatch locks. The last owner-thread control lease publishes cleanup-in-progress before dropping the dispatch lock; `waitForControlOps` waits for both the lease count and that in-progress flag. `finishOwnerThreadJsTeardown` frees JS resources on the creator and records completion only after release returns. This prevents the foreign destroyer from freeing instance synchronization while owner cleanup is still using it.

The no-owner-lease branch is different: `engine.destroyRuntime` reaches `releaseJsResources` on the foreign caller with `free_vm` false for Escargot, then clears engine handles and removes the registry entry. The VM and its bridge context remain allocated. `submission`'s foreign-destroy regression checks completion and registry disappearance, not VM reclamation or finalizer-thread correctness. A passing instance-map test must not be reported as leak freedom.

## Why thread registration is insufficient

The pinned `VMInstance` destructor accesses the calling thread's async-waiter vector, GC event-listener sets and pruning state. `ThreadLocal.finalize` finalizes that thread's heap. The bridge's runtime creation and destruction balance a thread-local enter depth; initializing another thread does not transfer the creator's heap, callbacks or enter-depth ownership. Removing the `free_vm` guard or deleting a copied handle from a replacement thread is not a safe repair.

The fallback's resource release also reaches `api_bind.dropInstance`, which invokes committed native binding finalizers synchronously. Its owner-thread contract therefore needs explicit validation; native callback ownership cannot be inferred from registry removal or from a noncrashing VM-leak fallback.

## Unresolved execution-model decision

A raw owner thread may be blocked joining the foreign destroyer and may never pump another event-loop turn. Posting cleanup to that owner can deadlock; retaining cleanup until a future owner entry or thread exit is not bounded reclamation. Moving all VM work to a dedicated executor, requiring a guaranteed host owner executor, or returning an explicit incomplete/unsupported foreign-teardown result would each change the current ownership or synchronous-destroy contract. Such a choice requires an explicit design decision and adversarial review rather than an unreviewed cleanup queue or an off-thread free.

The intentional fallback leak remains open. Source self-review is not external independent approval. Whole-PR acceptance still requires resolving this execution-model gap and reviewing owner finalizers, callback unwind, last-lease cleanup, registry removal and retained backend values together.

## Alternatives requiring an explicit decision

No safe bounded repair has been established that preserves the current execution model and all three guarantees together: arbitrary foreign-thread synchronous destroy, finalizers on the creator thread, and a creator that may block waiting for that destroyer. The following are design choices, not implemented fixes or approval to change the contract.

| Choice | Behavior and ownership | Safety and compatibility impact |
|---|---|---|
| Guaranteed owner executor | Destroy closes admission, dispatches teardown to the registered owner executor, and joins its completion. VM reclamation and native finalizers remain on their owner. | Requires an executor that is guaranteed to pump during the join; a raw creator blocked joining the destroyer cannot provide that guarantee. Executor shutdown, recursive destroy and last-lease cleanup require explicit ordering and adversarial tests. This adds a host scheduling requirement rather than repairing arbitrary raw-owner teardown transparently. |
| Dedicated VM owner | Every VM entry and teardown is marshalled to a runtime-owned executor, which serializes finalizers and joins destruction. | Avoids dependence on a passive creator, but changes the meaning of owner and the threading of callbacks. Synchronous reentry, nested engines, existing engine-thread wrappers and callback-triggered destruction need a wider execution-model design. It is not a small pinned-vendor patch. |
| Explicit owner-only or deferred completion API | Foreign callers receive an unsupported or pending result; the owner performs and acknowledges teardown through an explicit operation. | Makes lack of an executor observable and can preserve GC affinity, but cannot silently replace the current void synchronous destroy guarantee. A new API, compatibility policy and bounded host shutdown protocol would be required. |

Merely initializing GC on the foreign thread, deleting a copied VM handle, postponing cleanup until an optional future owner entry, or invoking finalizers on a helper thread does not satisfy the existing ownership and join requirements. A public C ABI owner/foreign finalizer probe must distinguish completion and callback count from callback-thread correctness; a registry-only success cannot certify reclamation.

## Executed owner-finalizer probe follow-up

Local evidence `startup-handshake-362beaa/bounded-diagnostics-status.json` and `public-owner-probes-status.json` now contains real C ABI runs, not only a prepared probe. On both API24 and API35, Escargot's diagnostic C-linked ELF and the unchanged packaged NG/QuickJS SDK libraries each produce the same result: owner destroy finalizes once on owner (exit zero); foreign destroy with the creator blocked in `pthread_join` finalizes once off owner (C exit 42; Escargot's Zig wrapper exits one). These are six actual foreign contract failures and six passing owner controls, with no crashes/timeouts. Hermes was not measured by this probe.

The dynamic result proves callback-thread mismatch. It does not measure VM allocation bytes or certify reclamation. The no-owner-lease Escargot VM/context leak remains established by `engine.zig:830-833` passing `free_vm=false`, and its unsafe off-thread destruction guard remains untouched. `releaseJsResources` invokes `api_bind.dropInstance` synchronously before the guarded VM release; committed finalizers are invoked directly in `abi/api_bind.zig:130-132,415-449`.

There is no safe transparent fix that can synchronously execute a callback on a creator that is blocked joining the destroyer and has no pumping executor. Direction is needed before changing this model: (1) require a guaranteed pumping owner executor, preserving affinity but adding a host scheduling requirement and deadlocking if the blocked creator is used as that executor; or (2) move VM ownership to a dedicated runtime executor, changing owner/callback-thread and reentry compatibility. An explicit asynchronous/pending teardown API would instead require a versioned API/migration decision; silently deferring the current synchronous void destroy would not meet its present join guarantee. No option is implicitly approved, and no outward contract or production execution model changed in this follow-up.

## Contract provenance clarification

The probe process code42 is not a destroy API status; destroy returns void. Header179-180 promises join, while the existing normative api-contract.md:7,9,51 supplies creator ownership and finalizer affinity; these exact statements predate the probe and are present in local main8e2aba7. The callback probe establishes count/thread, not VM freed bytes or a measured join failure. The separate free_vm=false source leak remains open. See [final-stage handoff](pr26-final-stage-handoff.md) for the compatibility decision; no extra probe requirement is promoted into a product contract.
