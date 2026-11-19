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
