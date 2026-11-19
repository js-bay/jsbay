# Escargot execution cancellation

## Pinned engine boundary

The pinned Escargot revision `ffd9b77ac17598c161d760d7bbe15bfca9179f02` has no public mid-script interrupt or execution-time-limit callback in `src/api/EscargotPublic.h`. `VMInstance::cancelAsyncWaiters` cancels atomic waiters; it is not a bytecode execution cancellation mechanism. The interpreter's existing debugger callbacks require debugger instrumentation and do not provide a general, debugger-independent execution deadline. A drain-boundary deadline cannot stop an infinite loop inside a single job.

The error observer's interrupted-rejection recovery contracts require cancellation to leave the observer quiet, preserve a pending promise and its original rejection value, and permit a later catch or unhandled-rejection notification after recovery. Registering an observer does not make those mid-script cancellation contracts complete.

## Maintainable pinned-source integration

A cancellation implementation can remain a reviewed patch against the pinned engine rather than requiring an engine upgrade. It needs a per-runtime, lifetime-owned polling callback at interpreter safepoints, including loop backedges and recursive entry. The callback must consult the existing host interrupt, execution-budget and shutdown state without acquiring locks that the executing thread already holds or retaining a destroyed instance.

Cancellation must be distinct from an ordinary ECMAScript exception. Throwing a regular error is insufficient: JavaScript catch/finally paths and Promise rejection conversion can swallow it or emit an incorrect observer event. `ByteCodeInterpreter.cpp` and `SandBox.cpp` currently handle `Value` exceptions; every relevant interpreter, Promise and evaluator boundary needs an explicit termination audit. Reusing debugger pause state would also couple runtime cancellation to Inspector attachment and corrupt stepping contracts.

The termination outcome must unwind engine-owned frames and GC roots safely, remain inside C++ until a reviewed evaluator boundary converts it to the existing host cancellation result, and never escape through an unprepared C or Zig callback frame. Nested evaluations need scoped cancellation ownership so one instance cannot consume or clear another instance's request. Recovery must reset only the completed entry's transient termination state, retain caller-owned interrupt/deadline settings, and preserve the remaining job queue and rejection identities.

## Acceptance boundary

Do not advertise mid-script interrupt support or convert existing failing cases into skips before the implementation is verified. Required regressions include the existing two interrupted-rejection recovery cases, loops under script catch/finally and Promise callbacks, recursive/nested evaluations, cancellation during host reentry, deadline reset, later microtasks, typed observer values, and owner-thread destruction. Exercise API24 and API35 with native safety checks retained, then obtain independent teardown and exception-unwind review. A normal throw, source rewriting, a longer timeout, or discarding pending jobs is not an equivalent implementation.
