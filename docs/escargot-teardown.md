# Escargot teardown ownership

## Creator affinity

The pinned Escargot VM destructor uses its calling thread's async-waiter, garbage-collector listener and heap-pruning state. Runtime creation and destruction also balance a thread-local enter depth. Registering another thread with the collector does not transfer the creator's heap, callbacks or enter-depth ownership. Do not remove the off-thread VM-release guard or free a copied runtime handle on a replacement thread.

## Explicit asynchronous completion

The generation-scoped destruction protocol closes admission on request and returns pending until the creator can drain outside admitted work and callbacks. The creator performs exactly-once native finalizers and backend VM/context release before completion is published. A foreign requester never synchronously dispatches back to a creator that may be joining it. An unavailable creator remains pending rather than claiming resource reclamation.

The legacy void destroy entry point cannot acknowledge asynchronous completion and is not a supported foreign-thread reclamation interface. Follow the [owner destruction protocol and migration guide](owner-destruction.md) for C, Zig, manual-owner and Android Looper hosts, including bounded-close compatibility and stale-generation handling.

## Verification and review boundary

Finalizer count, callback-thread affinity, registry disappearance and returned backend-free evidence are distinct properties; none should be substituted for another. Keep off-thread safety checks and test pending calls, duplicate requests, callback reentry, last-lease cleanup and owner exit together. Independent adversarial lifecycle review remains required alongside [execution termination and unwind review](escargot-cancellation.md).
