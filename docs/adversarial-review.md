# Escargot / Hermes spike — open risks

Hostile review snapshot of the Escargot / Hermes dual-backend spike (`-Dbackend=escargot|hermes`). Gated counts: Escargot **491 / 61 / 0**, Hermes **531 / 30 / 0**. See also `docs/capability.md` and `docs/production-gaps.md`.

## Correctness

| Severity | Finding | Mitigation / note |
|----------|---------|-------------------|
| Blocker (pre-mainline) | Escargot Context is thread-affine: cross-thread `hostInstall` / AtomicString / GC can SEGV. Same-thread refuse + `skipEscargotEtHost` (~24) hide the crash; they do not fix it. | Document Escargot ET+host as same-thread only; do not read gated pass counts as thick C ABI parity. |
| Blocker (product semantics) | Public `requestInterrupt` does not guarantee mid-script abort. Escargot has no public interrupt hook. Hermes does not arm sticky `asyncTriggerTimeout` on the user-interrupt path (stop/destroy use `requestStopInterrupt`). Spike returns `false` (`supportsMidScriptUserInterrupt`). | Keep return-value honesty; do not claim mid-script stop. |
| Major | Hermes sticky `asyncTriggerTimeout` poisons later evals unless host exits call `softRearmHermesStopAfterHost` / drain. | Every new host exit must soft-rearm. |
| Major | `native_handle` / External finalize is teardown-forced (`pending_finals`), not GC-precise. | Do not claim QJS-parity weak/GC finalizers. |
| Major | Escargot DestroyDefer (destroy-from-host during direct eval) ABRTs under bdwgc — Skip avoids the crash. | Permanent gap; do not peel UnlessGreen blindly. |
| Minor | Hermes transfer polyfill: source `byteLength` may stay non-zero after detach. | Documented quirk. |
| Minor | Hermes bytecode error stacks may lack filename (SkipZigTest). | Treat as partial. |
| Minor | No Hermes `ArrayBuffer.resize` (three permanent Skips). | Do not fake-resize. |

## API / ABI honesty

| Severity | Finding | Mitigation / note |
|----------|---------|-------------------|
| Major | `setMemoryLimit` always false. Hermes heap cap is create-time `GCConfig.MaxHeapSize` via Zig `EngineConfig` / `-Dhermes-max-heap` / `jsbay_engine_create_with_options` — not `jsbay_engine_create`. | Document; C hosts must use create2 for a heap cap. |
| Major | Soft `getMemoryUsage` reuses fields (`malloc_size` ← heap/allocated); not QuickJS layout. | Observation-only; warn SDK consumers. |
| Major | Hermes ESM is a host shim (not native module codegen); CJS is text-only (no QJS bytecode CJS cache). | Keep capability rows partial / text-only. |
| Major | Importing the full `engine_thread` suite ≠ all green: Hermes mostly green; Escargot has many EtHost / Interrupt / DestroyDefer Skips. | Publish Skip class tables, not only pass counts. |

## Build / CI / portability

| Severity | Finding | Mitigation / note |
|----------|---------|-------------------|
| Blocker (fresh clone) | `vendor/{escargot,hermes}-install` and `icu-prefix` are gitignored; submodules alone cannot run `-Dbackend=escargot\|hermes`. | Use `scripts/rebuild-{icu,escargot,hermes}-install.sh` or CI artifacts. |
| Major | Escargot needs THREADING + GNU2 TLS cmake flags; Zig test binary uses `use_lld=false` in one place. | Keep rebuild script authoritative. |
| Major | Hermes bridge must be `libhermes_bridge.so` sharing EH with hermesvm; Zig link needs `JSBAY_LIBSTDCXX` + `JSBAY_ICU_LIB_DIR` (not libc++). | Document toolchain matrix. |
| Major | `build.zig.zon` does not publish spike vendor trees; keep install trees out of zon paths. | Do not pollute the default backend. |
| Minor | Source pin SHAs must match submodule HEADs; bumping sources requires rebuild of install prefixes. | Keep capability pin table in sync. |

## Product / merge risks

| Severity | Finding | Mitigation / note |
|----------|---------|-------------------|
| Blocker | Spike tree vs public `jsbay_*` ABI: merge as experimental backends; keep the public ABI name. | No second product brand in-tree. |
| Major | Capability tables are easy to over-read as a production tag. | Title/docs say non-production / diminishing returns. |
| Major | Escargot is LGPL; Hermes/ICU need LICENSE redistribution with linked artifacts. | Compliance is a merge blocker. |
| Minor | Brand icons for upstream engines need careful trademark use. | Attribution; caution in marketing. |
| Minor | No CI job runs escargot/hermes yet. | Add optional/nightly before claiming mainline green covers the spike. |

## Android

NDK r27c + AVD `jsbay_api34` (TCG): QuickJS / Escargot / Hermes x86_64 evaluate smokes and `check-c-abi` pass. Full gated suite is not run on the emulator. Details: `docs/android-box-status.md`.

## Top blockers before mainline / production claims

1. Fresh clone cannot reproduce the spike from submodules alone (missing install/ICU + toolchain).
2. Keep `requestInterrupt` semantics honest (false ≠ mid-script stop).
3. Escargot cross-thread ET+host remains UB (Skip is not a fix).
4. Escargot LGPL + missing CI.
5. C ABI heap cap only via `jsbay_engine_create_with_options`, not `jsbay_engine_create`.

Cheap Skip→pass work on this tree is at diminishing returns; remaining gaps are mostly upstream or architectural.
