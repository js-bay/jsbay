# Codex PR #7 fix report

Branch: `spike/escargot-hermes-dual`  
Base HEAD when work started: `b9d39fab2d45e2d9f9b14693340bb4379613e577`  
Checklist: `/workspace/codex-pr7-findings.md` (37 findings)

## Status by finding

| # | Sev | Theme | Status | Notes |
|---|-----|-------|--------|-------|
| 1 | P1 | Docs English | ALREADY-FIXED | `docs/production-gaps.md`, `docs/android-box-status.md` are English current-state guidance |
| 2 | P1 | Lifetime | ALREADY-FIXED | `api_bind.spikeInstall` dups before consuming `set` |
| 3 | P1 | Lifetime | ALREADY-FIXED | Primitive wrappers go through `retainMove` / protect map |
| 4 | P1 | Buffers | ALREADY-FIXED | Pristine DataView getters + capacity check |
| 5 | P1 | Buffers | ALREADY-FIXED | Trusted `MutableBuffer` ArrayBuffer path |
| 6 | P1 | NH/finalizers | ALREADY-FIXED | Pending finalizer rolled back on attach failure |
| 7 | P1 | Misc | ALREADY-FIXED | HBC header validated before execute; script throws do not set decode_failed |
| 8 | P1 | NH | ALREADY-FIXED | Shared `HermesNhClaim` refcount |
| 9 | P1 | NH | ALREADY-FIXED | Callable closure retains `HermesNhState` |
| 10 | P1 | Misc | FIXED | Removed global setTimeout wrap; `allRejections` delivers tracker callbacks directly |
| 11 | P1 | ESM | ALREADY-FIXED | Fallback loader heap-allocated in context map |
| 12 | P1 | Docs/attrs | FIXED | Neutralized comparison-project attribution in value helpers |
| 13 | P1 | Docs/attrs | FIXED | Neutralized reference module attribution comments |
| 14 | P2 | Exception | FIXED | `*_value_to_string_result` + `spikeToUtf8` preserve throws |
| 15 | P2 | Exception | ALREADY-FIXED | `spikeToJson` via stringify OpResult |
| 16 | P2 | Exception | ALREADY-FIXED | C ABI uses get_property_result (owned undefined) |
| 17 | P2 | Exception | ALREADY-FIXED | get_property_result forwards getter throws |
| 18 | P2 | Exception | ALREADY-FIXED | call_result preserves thrown values |
| 19 | P2 | Exception | ALREADY-FIXED | set_property_result preserves setter throws |
| 20 | P2 | Exception | ALREADY-FIXED | json_parse_result |
| 21 | P2 | Exception | ALREADY-FIXED | hermesNewError / escargotNewError wired |
| 22 | P2 | Bind | ALREADY-FIXED | Publish verify via sameValue |
| 23 | P2 | Exception | ALREADY-FIXED | `spikeThrowValue` forwards owned exception |
| 24 | P2 | Misc | FIXED | Escargot Map/Set foreach via `Array.from` entries (no JSON) |
| 25 | P2 | Misc | ALREADY-FIXED | Hermes `Runtime::call` keeps primitive receivers |
| 26 | P2 | Buffers | FIXED | WeakMap has/get/set use `callWithThis` |
| 27 | P2 | Lifetime | ALREADY-FIXED | promise_state cleaned on `release` / forget |
| 28 | P2 | ESM | ALREADY-FIXED | Identifier rewrite skips object keys / member names |
| 29 | P2 | ESM | FIXED | Named re-export `require` at init; getter reads namespace |
| 30 | P2 | ESM | FIXED | `blankNonCode` masks strings/comments before export regexes |
| 31 | P2 | Lifetime | FIXED | `make_function_ex` + MethodBox free (Hermes NativeState; Escargot pending_finals) |
| 32 | P2 | Misc | ALREADY-FIXED | `hermes_is_symbol` / `escargot_is_symbol` wired |
| 33 | P2 | Lifetime | FIXED | `callFunctionNoArgs` frees owned return handle |
| 34 | P2 | Misc | FIXED | `log_user_data` gated on field offset+size |
| 35 | P2 | Misc | ALREADY-FIXED | `cleanupHolder` deletes via bridge delete_property |
| 36 | P2 | Buffers | FIXED (depends on #26) | Pins already keyed by `hermes_object_identity` |
| 37 | P2 | Lifetime | ALREADY-FIXED | registry uses `dispatch.newDataView` (defers free of temp AB) |

## Theme commits (this work)

Local commits on top of `b9d39fa` (not pushed from box):

1. `49e49a4` fix(hermes): identity callWithThis, to_string_result, MethodBox ownership
2. `832e1a6` fix(hermes-esm): blankNonCode export scan and named re-export init
3. `cd8891a` fix(escargot): foreach fidelity, to_string_result, MethodBox teardown
4. `9ba1930` fix(abi): exception-preserving toUtf8 and EngineCreateOptions size gate
5. `91160ae` docs: neutralize attribution comments and add Codex fix report
6. tip docs commit: record Codex fix commit SHAs in report (`git log -1 --oneline`)

## Builds / tests

- Vendor submodules (`vendor/hermes`, `vendor/escargot`) are not initialized in this checkout, so Hermes/Escargot C++ bridges were not compiled here.
- No cloud agent. Commits are local only; parent syncs/pushes from the Mac checkout.
- Recommended follow-up on a machine with engine prefixes: `zig build` for `-Dbackend=hermes` and `-Dbackend=escargot`, plus gated unit tests touching buffers.pin, native_handle methods, ESM re-exports, and C ABI toUtf8 exceptions.

## Remaining gaps / honesty

- Escargot MethodBox cleanup is teardown-forced via pending_finals (ExtraData has no GC finalizer). Hermes MethodBox frees on function NativeState destruction (GC or runtime teardown).
- ESM transformer remains a spike subset; `blankNonCode` is length-preserving masking, not a full JS parser (templates with `${}` nested braces are blanked as strings, which is conservative).
- Finding #1 documents were already English; no rewrite required beyond confirming current-state tone.
