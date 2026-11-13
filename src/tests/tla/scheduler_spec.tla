---- MODULE scheduler_spec ----
\* Formal specification of jsbay JS event loop scheduler state machine.
\* Extends the declaration module locked against Zig source types.
EXTENDS scheduler_model

VARIABLES
    state,
    saved_state,
    macro_q,
    micro_q,
    sync_depth

vars == <<state, saved_state, macro_q, micro_q, sync_depth>>

TypeOK ==
    /\ state \in States
    /\ saved_state \in {"idle", "in_task", "after_task", "in_checkpoint"}
    /\ macro_q \in 0..max_queued_tasks
    /\ micro_q \in 0..max_microtasks
    /\ sync_depth \in 0..max_sync_depth

Init ==
    /\ state = "idle"
    /\ saved_state = "idle"
    /\ macro_q = 0
    /\ micro_q = 0
    /\ sync_depth = 0

EnqueueMacro ==
    /\ macro_q < max_queued_tasks
    /\ macro_q' = macro_q + 1
    /\ UNCHANGED <<state, saved_state, micro_q, sync_depth>>

EnqueueMicro ==
    /\ micro_q < max_microtasks
    /\ micro_q' = micro_q + 1
    /\ UNCHANGED <<state, saved_state, macro_q, sync_depth>>

BeginQueuedTask ==
    /\ state = "idle"
    /\ macro_q > 0
    /\ micro_q = 0
    /\ sync_depth = 0
    /\ macro_q' = macro_q - 1
    /\ state' = "in_task"
    /\ UNCHANGED <<saved_state, micro_q, sync_depth>>

EndQueuedTask ==
    /\ state = "in_task"
    /\ sync_depth = 0
    /\ state' = IF micro_q > 0 THEN "after_task" ELSE "idle"
    /\ UNCHANGED <<saved_state, macro_q, micro_q, sync_depth>>

BeginCheckpoint ==
    /\ state \in {"after_task", "idle"}
    /\ micro_q > 0
    /\ sync_depth = 0
    /\ state' = "in_checkpoint"
    /\ UNCHANGED <<saved_state, macro_q, micro_q, sync_depth>>

DrainMicro ==
    /\ state = "in_checkpoint"
    /\ sync_depth = 0
    /\ micro_q > 0
    /\ micro_q' = micro_q - 1
    /\ UNCHANGED <<state, saved_state, macro_q, sync_depth>>

EndCheckpoint ==
    /\ state = "in_checkpoint"
    /\ sync_depth = 0
    /\ micro_q = 0
    /\ state' = "idle"
    /\ UNCHANGED <<saved_state, macro_q, micro_q, sync_depth>>

BeginSyncWait ==
    /\ sync_depth < max_sync_depth
    /\ sync_depth' = sync_depth + 1
    /\ saved_state' = IF sync_depth = 0 THEN state ELSE saved_state
    /\ state' = "in_sync_wait"
    /\ UNCHANGED <<macro_q, micro_q>>

EndSyncWait ==
    /\ sync_depth > 0
    /\ sync_depth' = sync_depth - 1
    /\ state' = IF sync_depth' = 0 THEN saved_state ELSE "in_sync_wait"
    /\ saved_state' = IF sync_depth' = 0 THEN "idle" ELSE saved_state
    /\ UNCHANGED <<macro_q, micro_q>>

Next ==
    \/ EnqueueMacro
    \/ EnqueueMicro
    \/ BeginQueuedTask
    \/ EndQueuedTask
    \/ BeginCheckpoint
    \/ DrainMicro
    \/ EndCheckpoint
    \/ BeginSyncWait
    \/ EndSyncWait

Spec == Init /\ [][Next]_vars

\* Safety Invariant: Active synchronous wait strictly correlates with in_sync_wait state.
Inv_SyncWaitStateConsistency ==
    sync_depth > 0 <=> state = "in_sync_wait"

\* Safety Invariant: When synchronous wait is inactive, saved_state must be idle.
Inv_SyncWaitIdleWhenInactive ==
    sync_depth = 0 => saved_state = "idle"

====
