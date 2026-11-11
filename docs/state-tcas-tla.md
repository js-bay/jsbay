# TLA+ specification lock and ITF trace replay

This document details the formal specification locking and counterexample trace replay integrated via `state_tcas.tla`.

## Overview

The `state_tcas` v0.3.0 integration provides two formal verification mechanisms:
1. **Declaration Anti-Drift Locking (`state_tcas.tla.lock`)**:
   Maintains a single source of truth by locking the TLA+ action/state vocabulary and bounded configuration constants generated from native Zig types against checked-in golden specifications (`docs/tla/scheduler_model.tla`).
2. **Apalache ITF Trace Replay (`state_tcas.tla.replayJsonTrace` / `replayJsonTraceWithOptions`)**:
   Replays execution traces and model-checker counterexamples (in Informal Trace Format) against the live `js_event_loop.Scheduler` harness (`SchedulerTlaContext`), validating enabling guards (`error.ActionNotEnabled`) and state projection alignment (`error.TraceDiverged`).

## Locked Models and Traces

| Artifact | Type | Description | Harness |
| --- | --- | --- | --- |
| [scheduler_model.tla](tla/scheduler_model.tla) | TLA+ Specification | Locked declarations for JS event loop Scheduler vocabulary and bounds | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler_task_checkpoint_trace.json](tla/scheduler_task_checkpoint_trace.json) | Positive ITF Trace | Replay of canonical task execution followed by microtask checkpoint drain | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler_sync_wait_rejection_trace.json](tla/scheduler_sync_wait_rejection_trace.json) | Negative ITF Trace | Counterexample verifying queued task execution rejection during synchronous wait | `src/tests/state_tcas_tla_harness.zig` |

## Regenerating Golden Specifications

If vocabulary or configuration constants intentionally change, update the locked specification from the jsbay package root:

```sh
touch .state_tcas-update-tla
zig build test-state-tcas -Dtest-filter="lock"
rm -f .state_tcas-update-tla
```

## Running Verification

To run all `state_tcas` harnesses including TLA+ specification locks, trace replay, and explore gate checks:

```sh
zig build test-state-tcas
```

To run exclusively the TLA+ harness:

```sh
zig build test-state-tcas -Dtest-filter="state_tcas tla:"
```
