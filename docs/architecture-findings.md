# Architecture findings

The highest-priority issue is that backend order determines whether a dual-engine library compiles. The build accepts either engine as primary, but some operations on a secondary instance still require the primary engine's value type. The build evidence below is for revision `ad4bb9e`. The remaining findings identify specific paths to verify before changing the runtime or its public API.

## Dual-engine builds

On an Apple target with Zig 0.17.0, the first tag in `-Dbackends` selects the primary engine. The library command was `zig build -Dlibrary-only=true -Dbackends=<pair>`. The suite command was `zig build test-engine -Dbackends=<pair> -Dtest-filter=packed --summary all`.

| Backend pair | Library build | Packed tests |
| --- | --- | --- |
| `quickjs_ng,jsc` | Produced the archive | 20 passed, 1 skipped |
| `quickjs,jsc` | Produced the archive | 19 passed, 2 skipped |
| `jsc,quickjs_ng` | Two compile errors | A targeted secondary-backend evaluation test also failed to compile |
| `jsc,quickjs` | Two compile errors | Suite not run |

Both failing builds reject a QuickJS-family value at two boundaries. The rejection observer calls `api_value.putBorrowed` with a native Promise value, and the Inspector path calls `reportRejection` with native Promise and reason values. Both receivers expect `ActiveEngine.Value`, which is a JSC value pointer in these builds. The dual-engine CI step selects QuickJS-NG as primary. [QuickJS observer](../src/backend/quickjs/exception.zig) · [QuickJS-NG observer](../src/backend/quickjs_ng/exception.zig) · [ABI value storage](../src/abi/api_value.zig) · [Inspector exceptions](../libs/inspector/src/exceptions.zig) · [CI configuration](../.github/workflows/ci.yml)

Keep native value ownership with the instance's backend when passing a borrowed value to an observer. Build all four pairs, then exercise evaluation, rejection observation and handle release on a real secondary instance. Arithmetic alone does not exercise either failing interface.

## Execution and capability boundaries

- **Execution budgets.** Primary C evaluation keeps an outer execution scope through the checkpoint. Secondary C evaluation calls `execution.end()` before `checkpointInstance`; with no enclosing budget, the checkpoint can establish a new deadline. The scheduler already provides `checkpointInstanceAfterExecution` to retain the original budget. JSC handles Promise reactions inside the VM. Its explicit pending-job hook runs deferred finalizers, so the change in scope alone does not establish that a JSC Promise callback gets extra time. Measure the deadline at the relevant callback on each supported secondary backend. [C evaluation](../src/c_api.zig) · [Scheduler](../src/runtime/js_scheduler.zig) · [JSC pending jobs](../src/backend/jsc/lifecycle.zig) · [Primary deadline test](../src/tests/runtime_boundary_tests.zig)
- **Module evaluation.** For a secondary instance, `getPtrs` returns the event loop and a zero placeholder for the primary engine's context. Internal `evalModule` and `importModule` select the compile-time backend and pass that context onward. Separate loop lookup from typed context access. Test that each internal entry point either dispatches to the actual backend or returns an explicit unsupported result. The runtime consequence through a public SDK has not been demonstrated. [Instance lookup](../src/runtime/instance_map.zig) · [Module entry points](../src/engine.zig)
- **Capability discovery.** A host can select a backend per instance. The public capability query describes the library primary, while operations such as native binding explicitly reject a secondary instance. An instance-level query would let a host check its required operations before initialization. Keep the library query for build identity and verify each instance capability against the corresponding operation. [Public header](../include/jsbay.h) · [Capability flags](../src/backend.zig) · [Binding entry point](../src/c_api.zig)

## Ownership and directory boundaries

| Finding | Consequence and next check |
| --- | --- |
| [Engine teardown](../src/engine.zig) explicitly releases ABI handles, callbacks, CommonJS references and timers before freeing the VM. | A new resource retaining a JS value needs a matching release in a different directory. Preserve the explicit order and test callback-initiated destruction, pending work and reuse of an instance ID before moving responsibilities. |
| [Thread state allocation](../src/runtime/engine_thread.zig) uses the C allocator and collapses allocation failure into denied entry. The [ABI admission path](../src/abi/value_operation.zig) translates denial for an existing instance into a wrong-thread error. | A caller on the correct thread can receive misleading recovery advice. Carry the failure reason to the ABI and inject failure during first entry to verify the out-of-memory status. |
| The [scheduler](../src/runtime/js_scheduler.zig) looks up the context at the start and end of a backend drain. Each lookup scans the [locked instance registry](../src/runtime/instance_map.zig). | The lookup cost grows with the number of instances. Measure short tasks with 1, 16 and 128 live instances before adding a reverse index. The latency impact is unmeasured. |
| The [Zig package root](../src/root.zig) exports the entire runtime control module, including teardown and budget bookkeeping, alongside curated C ABI declarations. The [architecture guide](architecture.md) lists six local packages, while the [manifest](../build.zig.zon) and [package test target](../build.zig) include nine. | Identify which Zig declarations consumers may rely on before changing exports. Reconcile the package inventory, including the public utility modules, with the build manifest. The existing CommonJS split provides a useful precedent for keeping VM-specific operations in the engine. |

Prioritize the two failing builds, then verify execution and capability behavior across primary and secondary instances. Changes to ownership or directory layout can follow once those behaviors have regression coverage. Independent review, mobile-device runs, full backend suites and scaling measurements remain open.
