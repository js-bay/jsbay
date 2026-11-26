# Architecture findings

Multi-engine configurations allow embedding applications to pair different JavaScript runtimes within a single process. The first tag specified in the `-Dbackends` build option designates the primary engine, while subsequent tags configure secondary backends.

## Dual-engine architectures

Native value ownership remains bounded to the instance's engine backend. When passing borrowed references to host observers or inspector exceptions, the runtime must retain the instance's backend type rather than assuming primary engine representation. Both engine orders must maintain parity across evaluation, rejection observation, and handle release.

## Script submission semantics

Secondary instances reject asynchronous public script submission through `acceptsPublicSubmission`. Event loop drivers (`jsbay_engine_run_loop` and `jsbay_engine_attach_loop`) are supported on primary instances, while secondary instances execute synchronous direct evaluation. Teardown cancellations follow the unified completion contract.

Submission routines discard success values without evaluating prototype accessors, preserving identical execution semantics between direct evaluation and task dispatch.

## Execution and capability boundaries

- Execution budgets: Evaluation scopes maintain budget checkpoints through task execution boundaries. When nested evaluations or Promise reaction jobs run, checkpoint validation preserves the active execution deadline across engine types.
- Module evaluation: Secondary instance lookups resolve dedicated event loops and typed context handles. Internal module loading dispatches directly to the instance's engine backend or returns an explicit unsupported status.
- Capability discovery: Library capabilities describe primary compile-time features, while instance capabilities dynamically reflect live instance backend configurations across heap limits, bytecode formats, and inspector protocols.
