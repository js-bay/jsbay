# Escargot / Hermes — production gaps vs QuickJS-NG / JSC

Fact source: `docs/capability.md`. Gaps ranked by impact on embedding hosts. This spike is **not** a production engine tag.

## Must (blocks treating the backend as production-ready)

| Gap | Impact | Location | Status |
|-----|--------|----------|--------|
| CJS / `require` | Host script / bundle main path | `src/script/cjs.zig`, backend `evalValue` + `makeNativeFunction` | Text path wired; no QuickJS-shaped bytecode CJS cache |
| `errors.throwError` / host throw | Native callback `try/catch` | `src/value/errors.zig`, `*Backend.throwError` → `*_throw` | Wired (`pending_throw`; kind not forwarded into the bridge) |
| Hermes host-throw stability | `NativeResult.err` / CJS missing-module / value `.err` | `libhermes_bridge.so` + `throw jsi::JSError` | Stable when bridge shares libstdc++/libgcc_s with hermesvm |
| `native_handle` (opaque + call + finalize + method) | SDK / host-callable objects | `*/native_handle.zig` + ExtraData/NativeState; MethodBox `*_dup` on setMethod | Method this-binding works; finalize is teardown-forced |
| Thick C ABI / `engine_thread` contract | Multi-instance / host threading | Smoke + full suite | Hermes hostInstall / destroy-defer / nested / filename / after-stop green; Escargot host/dispatch skipped (Context is thread-affine; same-thread only) |
| Heap limit / interrupt | Resource guardrails | `runtime_control` parity | Hermes stop/destroy can mid-script; user `requestInterrupt` does not guarantee mid-script stop on either backend (Escargot has no public hook; Hermes does not arm sticky `asyncTriggerTimeout` for user interrupt); `setMemoryLimit` always false; Hermes create-time `MaxHeapSize` via Zig/`js_bay_engine_create2`; soft `getMemoryUsage` |

## Should (closer to QuickJS / JSC experience)

| Gap | Location |
|-----|----------|
| Hermes Promise rejection tracker | `HermesInternal.enablePromiseRejectionTracker` + flush after drain; module-shim throw → `hermes_report_unhandled_rejection` |
| Hermes ESM remainder | TLA via async wrapper + `awaitThenable`; sticky-fail + JSON attributes; other shim limits remain |
| Hermes `object_ops` | Suite green; destroy-during-trap via `api_bind.spikeInstall` |
| Buffer copy / transferable | C `copyBuffer` imported; exotic-getter green; Hermes `ArrayBuffer.resize` permanently skipped (no native `.resize`) |
| Inspector / CDP | Long-term; debugger hooks exist on QuickJS-NG only |

## Later

| Gap | Notes |
|-----|-------|
| Escargot on-disk bytecode | No public blob API |
| Hermes async / async-gen fixtures | Stripped in this Hermes build |
| GC-precise weak / external | Teardown-forced today |
| Escargot interrupt (permanent) | `EscargotPublic` has no interrupt / ExecutionTimeLimit / async-break API; approximate only at job/host boundaries |
| Both `setMemoryLimit` (permanent false) | Escargot has no cap API; Hermes has no runtime set — use create-time `EngineConfig.max_heap_size` / `-Dhermes-max-heap` → `GCConfig.MaxHeapSize` |
| Hermes create-time MaxHeapSize | `hermes_runtime_new(max)` + `EngineConfig` + `js_bay_engine_create2`; `0` → `-Dhermes-max-heap` → 3GiB |
| Honest `requestInterrupt` | Spike returns `false` (`supportsMidScriptUserInterrupt`); stop/destroy can still mid-script on Hermes |
| Fresh-clone rebuild scripts | `scripts/rebuild-{icu,hermes,escargot}-install.sh` |
| Soft `getMemoryUsage` | Non-QJS field layout; `malloc_size` ≈ heap/allocated; `setMemoryLimit` still refused |
| CI matrix + ABI freeze | Prerequisite for a production tag |

## Verify

```bash
export JSBAY_LIBSTDCXX=/home/box/.local/gcc-root/usr/lib/gcc/x86_64-linux-gnu/14/libstdc++.a
export JSBAY_ICU_LIB_DIR=/workspace/jsbay-dual-spike/vendor/icu-prefix/lib
zig build test-engine -Dbackend=escargot -Dlibstdcxx="$JSBAY_LIBSTDCXX"
zig build test-engine -Dbackend=hermes -Dlibstdcxx="$JSBAY_LIBSTDCXX" -Dicu-lib-dir="$JSBAY_ICU_LIB_DIR"
```

Install prefixes live under `vendor/{escargot,hermes}-install`. Rebuild Escargot `escargot_bridge.o` after bridge edits; rebuild Hermes `libhermes_bridge.so` after bridge edits (do not link a Hermes bridge `.o` into Zig).

### Escargot mid-script interrupt — permanent gap

Pinned `vendor/escargot-install/include/EscargotPublic.h` and `vendor/escargot/src/api/*` expose no `interrupt` / `Interrupt` / `ExecutionTimeLimit` / `asyncBreak` / `shouldStop` symbols. Public surface covers `Memory::gc` / `heapSize` / `totalSize` / `setGCFrequency`, Evaluator, and VMInstance Promise hooks. Hermes has `IHermes::asyncTriggerTimeout` + `watchTimeLimit` + bytecode `AsyncBreakCheck`. Mid-script `requestInterrupt` is impossible without upstream Escargot changes; `skipSpikeNeedsNativeInterrupt` is permanent.

### Skip classes (summary)

| Class | Hermes (~30) | Escargot (~61) |
|-------|--------------|----------------|
| Permanent | resize×3; CJS bytecode cache; spike-wide (dataview/exception/engine/cjs); transfer tight cap; ESM build cuts | EtHost×24 (Context thread affinity); NativeInterrupt×5; DestroyDefer×2 (bdwgc ABRT); no bytecode blob; same spike-wide |
| Peeled | destroy-defer / nested / filename / after-stop | after-stop / nested / filename-throw; memory smoke |
| Peelable but not cheap | none left cheap | DestroyDefer needs lifecycle rewrite; EtHost = per-ET Context |

### Gated counts

- Escargot: **491 pass / 61 skip / 0 fail**
- Hermes: **531 pass / 30 skip / 0 fail**

Further peel of Escargot ET+host / interrupt / DestroyDefer, or Hermes resize / `setMemoryLimit`, needs upstream work or a large refactor.
