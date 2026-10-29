# Upstream known issues (do not patch vendor/)

**Policy:** if a defect lives in QuickJS or QuickJS-NG, document it here and leave `vendor/` alone. Attribute carefully; prefer linking an upstream issue when one exists.

## NG-1 — OOM path retains one extra atom (`malloc_count` +1)

| Field | Value |
| --- | --- |
| **Symptom** | After an OOM sweep that tightens the heap, exercises host APIs, lifts the limit, and runs GC, `JS_ComputeMemoryUsage` can report `malloc_count = settled + 1` and `atom_count = settled + 1` (with a small `malloc_size` delta) while **`obj_count` is unchanged**. |
| **Backends** | **quickjs-ng only**. Classic `quickjs` keeps `malloc_count` at the pre-sweep baseline (atoms may still rise without a `malloc_count` change). |
| **Repro** | `zig build test-engine -Dbackend=quickjs_ng -Dtest-filter='oom sweep: host APIs'`, or run the same sweep and diff `getMemoryUsage` before/after GC. |
| **Rationale** | JS Bay only forwards `JS_SetMemoryLimit` / `JS_ComputeMemoryUsage` / `JS_RunGC`. There is no custom `JS_NewRuntime2` allocator. Because `obj_count` returns to baseline, this is allocator/atom-table retention inside quickjs-ng after OOM paths—not a host-API object leak in JS Bay. |
| **JS Bay response** | Tests assert exact `obj_count` and allow `malloc_count` drift **only** when it matches `atom_count` growth. **Do not patch `vendor/quickjs-ng`.** |
| **Upstream follow-up** | Track against quickjs-ng: an atom (or equivalent) retained after OOM failure paths that classic QuickJS does not keep in `malloc_count`. |

## Intentionally not upstream

| Topic | Why it is JS Bay-owned |
| --- | --- |
| Debug stack recover with a fixed reserve | `stack_budget` left too little JS budget after a fixed reserve; Debug `JS_Eval` prologue alone can exceed that. Fixed in `src/platform/stack_budget.zig` (including stack-top sync before JS entry). |
| Borrowed `retain` / `free_bytes` docs | Contract text versus implementation; docs and tests only. |
