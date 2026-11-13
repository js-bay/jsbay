# TLA+ specification lock and ITF trace replay

This document details the formal specification locking and counterexample trace replay integrated via `state_tcas.tla`.

## Overview

The `state_tcas` v0.3.0 integration provides two formal verification mechanisms:
1. **Declaration Anti-Drift Locking (`state_tcas.tla.lock`)**: Maintains a single source of truth by locking the TLA+ action/state vocabulary and bounded configuration constants generated from native Zig types against checked-in golden specifications (`src/tests/tla/scheduler_model.tla`).
2. **ITF Trace Replay (`state_tcas.tla.replayJsonTrace` / `replayJsonTraceWithOptions`)**: Replays execution traces and counterexamples (authored in Apalache Informal Trace Format ADR-015 structure) against the live `js_event_loop.Scheduler` harness (`SchedulerTlaContext`), validating enabling guards (`error.ActionNotEnabled`) and multi-variable state projections (`error.TraceDiverged`).

## Formal Specifications and Traces

| Artifact | Type | Description | Harness |
| --- | --- | --- | --- |
| [scheduler_model.tla](../src/tests/tla/scheduler_model.tla) | TLA+ Module | Locked declarations for JS event loop Scheduler vocabulary and bounds | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler_spec.tla](../src/tests/tla/scheduler_spec.tla) | TLA+ Specification | State machine specification extending `scheduler_model` with safety invariants | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler.cfg](../src/tests/tla/scheduler.cfg) | TLC Configuration | Model checker configuration asserting TypeOK and consistency invariants | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler_task_checkpoint_trace.json](../src/tests/tla/scheduler_task_checkpoint_trace.json) | Positive ITF Trace | Replay of canonical task execution followed by microtask checkpoint drain | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler_sync_wait_lifecycle_trace.json](../src/tests/tla/scheduler_sync_wait_lifecycle_trace.json) | Positive ITF Trace | Replay of synchronous native wait entry and exit lifecycle | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler_sync_wait_rejection_trace.json](../src/tests/tla/scheduler_sync_wait_rejection_trace.json) | Negative ITF Trace | Counterexample verifying queued task execution rejection during synchronous wait | `src/tests/state_tcas_tla_harness.zig` |
| [scheduler_checkpoint_sync_wait_rejection_trace.json](../src/tests/tla/scheduler_checkpoint_sync_wait_rejection_trace.json) | Negative ITF Trace | Counterexample verifying microtask drain rejection during sync wait within checkpoint | `src/tests/state_tcas_tla_harness.zig` |

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
