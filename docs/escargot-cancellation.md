# Escargot execution cancellation

## Pinned engine boundary

The pinned Escargot revision `ffd9b77ac17598c161d760d7bbe15bfca9179f02` has no reusable mid-script interrupt or execution-time-limit hook. `VMInstance::cancelAsyncWaiters` only cancels atomic waiters, and debugger callbacks are not a general execution deadline. `vendor/escargot-execution-termination.patch` supplies a separate cancellation path without upgrading the pin or converting termination into an ECMAScript exception.

## Polling and host ownership

Each VM borrows an owner-thread callback and its live context from the bridge; context destruction disconnects the callback before releasing that context. The callback reads the existing effective execution deadline, including manual limits, per-entry budgets and shutdown grace, without retaining an instance. Unsupported user-interrupt and lifecycle-stop capabilities remain unchanged; the patch does not advertise support for them.

The interpreter polls every 1024 opcodes and at interpreted entry. Native function return also polls before JavaScript resumes, after the native callback and its C or Zig frames have returned. The callback only returns a boolean; C++ raises the termination outcome after that callback returns. Polling does not preempt a long native builtin, a parser operation or a blocked foreign callback.

## Termination and unwind safety

`ExecutionTermination` is distinct from `Value`. JavaScript catch/finally, Promise executor rejection conversion and internal job sandboxes do not consume it. Internal sandboxes rethrow it until an explicit public evaluator or pending-job boundary produces an unsuccessful `wasTerminated` result. Formatting that result uses constant text rather than executing a user conversion or creating a rejection value. Both public nonthrowing string conversion and script-error formatting execute under a termination-aware boundary; merely constructing a sandbox object does not catch an exception. There is no `longjmp` or source rewriting.

Paused-frame evaluation and scope copying run inside protected C++ evaluators before returning through the bridge. Scope property reads can execute accessors, so protecting only explicit debugger expressions is insufficient. A termination must not unwind through Inspector's C or Zig frames, whose deferred cleanup is outside the C++ exception contract.

C++ unwinding retains ordinary RAII cleanup. Execution pausers additionally clear their program-counter pointer, release suspended roots and mark interrupted generators complete without running Promise rejection or resolution handlers. Saved debugger stack-trace state is restored on both normal and exceptional exits. The parent execution-state binder remains an ordinary stack-owned guard.

## Recovery and observers

A protected host boundary consumes its transient termination outcome, not the host's deadline setting. The next JavaScript safepoint polls that unchanged deadline again. An explicit host recovery may clear the manual deadline before returning to JavaScript; script catch and Promise rejection machinery cannot do so. Separate instances retain separate callback ownership. A completed entry does not discard the remaining job queue or synthesize an error-observer event, so retained rejection values can be caught or reported after recovery.

## Acceptance boundary

Focused regressions cover catch/finally, Promise executors and jobs, async continuation, nested host entry with and without explicit host recovery, separate instances, entry budgets, generator cleanup, terminating error-object conversions, original rejection identities and later job/GC/evaluation recovery. The existing paused-frame TDZ regression also exercises a terminating scope accessor and successful recovery. Existing capability-gated skips remain unchanged.

These focused results do not certify replacement four-engine full suites, all interrupted module states, every async-generator request sequence, ARM64 hardware, or every native builtin. Independent exception-unwind and adversarial teardown review remains required. Keep the PR Draft until the broader handoff acceptance boundary is met; a normal throw, a longer timeout, dropped jobs, disabled safety checks or unsupported skips are not equivalent fixes.
