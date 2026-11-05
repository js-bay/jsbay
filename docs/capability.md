# Escargot / Hermes — capability vs QuickJS

Backends selected with `-Dbackend=escargot` or `-Dbackend=hermes`. ABI is not frozen yet (full engine_thread suite / inspector / QJS native_handle class_id still missing; Escargot has rejection tracker; spike native_handle opaque+call+finalize+method this-binding; Hermes host ESM shim). Suite lists below are what `src/tests/all_tests.zig` imports for each backend; out-of-scope suites stay out of the aggregator. Production gap ranking: `docs/production-gaps.md`.

Shared tree: both engines live under `src/backend/{escargot,hermes}/`. Build one at a time via `-Dbackend=…` (not a multi-engine pack).

## Escargot (`-Dbackend=escargot`)

Scope: eval, value/object, Promise (+ host rejection tracker), buffers, timers, host_object, ESM (ModuleLoader), text CJS/`require` (no QJS-shaped bytecode CJS cache).

| Area | Status | Notes |
|------|--------|-------|
| eval / script | **yes** | `initializeScript` + `Evaluator::execute` |
| value / object / atoms | **yes** | primitives, objects, arrays, construct, keys, delete, instanceof |
| object_ops suite | **yes** | imported; destroy-during-trap green (`jsbay_engine_bind` spikeInstall trampoline) |
| strictEquals (`===`) | **yes** | `ValueRef::equalsTo` |
| arrayGet / arraySet / arrayClear | **yes** | holes → `undefined` |
| defineDataProperty | **yes** | writable true/false |
| Symbol / Symbol.for | **yes** | |
| isConstructor | **yes** | |
| Promise / Deferred | **yes** | |
| Map / Set / Date / BigInt | **yes** | |
| ArrayBuffer / TypedArray / DataView | **yes** | zero-length + shadowed. Resizable length-tracking OOB: Public view zeros OOB — cannot match QuickJS `dataViewInfo→null`. Transfer: **native** (see buffer row) |
| timers / queueMicrotask | **yes** | |
| host_object | **yes** | Proxy traps |
| external / weak finalizers | **partial** | teardown-forced; not GC-precise |
| ESM ModuleLoader | **yes** | load + resolve rewrite + circular link (forward). Reverse named-fn may stay TDZ |
| CJS / require | **yes** | text path via `evalValue` + native `require`; no bytecode CJS cache |
| host `throwError` | **yes** | `escargot_throw` → pending_throw (kind not preserved) |
| bytecode / .hbc blob | **no** | no Public bytecode blob API |
| disk bytecode cache | **no** | |
| native_handle | **partial** | ExtraData opaque + call + finalize (teardown-forced; no GC finalizer — UAF with pending_finals); MethodBox this-binding; no QJS class_id / CallbackStore suite |
| engine_thread / thick C ABI | **partial** | full suite; hostInstall **same-thread only**; `skipEscargotEtHost` kept (Context thread-affine); DestroyDefer×2 permanent (bdwgc ABRT); mid-script interrupt **permanent** (no EscargotPublic hook) |
| heap limit / interrupt | **partial** | `runGc` → `Memory::gc`; soft `getMemoryUsage` via `Memory::heapSize`/`totalSize`; **no** mid-script interrupt (permanent); `requestInterrupt` returns true but only sets a bit; `setMemoryLimit`→false (permanent); no create-time heap cap |
| inspector / CDP / debugger | **no** | |
| rejection tracker | **yes** | `registerPromiseRejectCallback`; report after microtask drain |
| buffer copy / transferable | **partial** | native transfer green; C `copyBuffer` imported; DataView OOB-after-resize → INVALID (aligned with QJS) |

## Hermes (`-Dbackend=hermes`)

Scope: eval, value/object, Promise, buffers, timers, host_object, `.hbc` bytecode (hermesc + JSI), text CJS/`require`, host-side ESM ModuleLoader shim (`hermes_esm.cpp` — pin has no native CJS/ESM codegen).

| Area | Status | Notes |
|------|--------|-------|
| eval / script | **yes** | JSI `evaluateJavaScript` |
| value / object / atoms | **yes** | |
| object_ops suite | **yes** | imported; Proxy trap/exception green; destroy-during-trap green (spikeInstall) |
| strictEquals (`===`) | **yes** | |
| arrayGet / arraySet / arrayClear | **yes** | |
| defineDataProperty | **yes** | |
| Symbol / Symbol.for | **yes** | |
| isConstructor | **yes** | Reflect.construct newTarget probe |
| Promise / Deferred | **yes** | |
| Map / Set / Date / BigInt | **yes** | Map/Set foreach via entries/values snapshot (no HostFunction callback) |
| ArrayBuffer / TypedArray / DataView | **yes** | zero-length + shadowed. No `.resize`. Transfer: **polyfill** (`HermesInternal.detachArrayBuffer` + WeakSet `detached`; source `byteLength` may stay non-zero) |
| timers / queueMicrotask | **yes** | |
| host_object | **yes** | JSI HostObject + Proxy |
| external / weak finalizers | **partial** | teardown-forced |
| bytecode / .hbc | **yes** | hermesc + JSI Buffer |
| disk bytecode cache | **yes** | `cache_tests` with `-Dbytecode-cache` |
| ESM ModuleLoader | **partial** | Host ESM→CJS shim (`hermes_esm.cpp`); sticky-fail + JSON attr; dynamic-import missing catchable; **TLA via async wrapper + awaitThenable** (modules TLA test green) |
| CJS / require | **yes** | text path; bytecode CJS cache bypassed (use .hbc separately) |
| host `throwError` | **yes** | `hermes_throw` + HostFunction `throw jsi::JSError` via `libhermes_bridge.so` (shared libstdc++/libgcc_s with hermesvm; avoids Zig libunwind ABRT) |
| native_handle | **partial** | NativeState opaque + call + finalize (NativeState dtor + pending_finals claim); MethodBox this-binding (hermes_dup on setMethod); no QJS class_id suite |
| engine_thread / thick C ABI | **partial** | full suite; hostInstall + destroy-defer + nested + filename + after-stop + stop-interrupt green; bind_sync 5/5 |
| heap limit / interrupt | **partial** | soft `getMemoryUsage` via `getHeapInfo`; **create-time** `MaxHeapSize` via Zig `EngineConfig.max_heap_size` / `-Dhermes-max-heap` (**not** in `jsbay_engine_create` C ABI); `setMemoryLimit`→false; **user** `requestInterrupt` = bit only (no mid-script); stop/destroy mid-script via `asyncTriggerTimeout` + softRearm/drain |
| inspector / CDP / debugger | **no** | |
| rejection tracker | **yes** | `HermesInternal.enablePromiseRejectionTracker` + host queue/flush after microtask drain; setTimeout(100|2000) → cancellable double-microtask (Escargot-style sync-catch silence); module-shim top-level throw via `hermes_report_unhandled_rejection` |
| buffer copy / transferable | **partial** | transfer polyfill green; C `copyBuffer` imported; exotic-getter green (pristine `%TypedArray%` brand+getters); Hermes `.resize` windows still Skip |
| native_function host-throw | **yes** | NativeResult.err / nested throw / CJS missing-module / value `.err` OK; getPropertyString loop green (`var` across Hermes evals) |
| async / async generators in fixtures | **no** | this Hermes build strips them |

`JSBAY_HERMESC` overrides hermesc if it is not on `PATH` / `vendor/hermes-install/bin/hermesc`.

## Hardening (both)

- `setProperty` rejects keys with embedded NUL (NUL-terminated C bridge).
- Double `engine.destroy` is a no-op after the first.
- Pending timers dropped on destroy (no UAF).
- Deferred abandon-without-settle is safe.
- Hermes: `hermesCompileBytecode` does not pass an undefined empty-slice `.ptr` to C; hermesc via fork/exec (not shell).

## Local build

### Source pins (git submodules)

| Path | Upstream | Pinned commit |
|------|----------|---------------|
| `vendor/escargot` | https://github.com/Samsung/escargot.git | `ffd9b77ac17598c161d760d7bbe15bfca9179f02` |
| `vendor/hermes` | https://github.com/facebook/hermes.git | `9a51f48dcbccf0eddd0b67c687d17b3ab4cede58` |

These match the revisions the C bridges / install prefixes were built against.
Install / build trees stay **local** (gitignored): `vendor/escargot-install`, `vendor/hermes-install`, `vendor/hermes-build`, `vendor/icu-prefix`.

```bash
# sources (QuickJS + Escargot + Hermes)
git submodule update --init --recursive vendor/quickjs vendor/quickjs-ng \
  vendor/escargot vendor/hermes
# Escargot needs its own nested deps (at least third_party/GCutil) to rebuild
# from source; --recursive covers that. Hermes has no nested gitmodules.
```

**Scripts (fresh clone):** `scripts/rebuild-icu-prefix.sh` → `scripts/rebuild-hermes-install.sh`; `scripts/rebuild-escargot-install.sh` (THREADING + GNU2 TLS + bridge). Then compile bridges as below / via scripts.

Rebuild each engine into a prefix, then compile the bridge `.o` into that prefix. Point Zig at the prefix with `-D` / env:

```bash
# shared toolchain bits (g++ local-exec TLS; Zig must not link libc++)
export JSBAY_LIBSTDCXX=/path/to/libstdc++.a
export JSBAY_ICU_LIB_DIR=/path/to/icu/lib          # Hermes only
# optional:
# export JSBAY_HERMESC=/path/to/hermesc
# -Descargot-install=... -Dhermes-install=...

# Hermes bridge MUST be a shared lib (throw path shares EH with hermesvm):
g++ -shared -fPIC -std=c++17 -O0 -g \
  -I src/backend/hermes -I vendor/hermes-install/include \
  -L vendor/hermes-install/lib -L "$JSBAY_ICU_LIB_DIR" \
  -Wl,-rpath,'$ORIGIN' -Wl,-rpath,"$JSBAY_ICU_LIB_DIR" \
  -o vendor/hermes-install/lib/libhermes_bridge.so \
  src/backend/hermes/hermes_bridge.cpp src/backend/hermes/hermes_esm.cpp \
  -lhermesvm -ljsi -lgcc_s
# Escargot → vendor/escargot-install/lib/escargot_bridge.o (static .o into Zig link)
g++ -c -std=c++17 -O0 -g -fPIC \
  -I src/backend/escargot -I vendor/escargot-install/include \
  -o vendor/escargot-install/lib/escargot_bridge.o \
  src/backend/escargot/escargot_bridge.cpp

zig build test-engine -Dbackend=escargot \
  -Dlibstdcxx="$JSBAY_LIBSTDCXX"

zig build test-engine -Dbackend=hermes \
  -Dlibstdcxx="$JSBAY_LIBSTDCXX" \
  -Dicu-lib-dir="$JSBAY_ICU_LIB_DIR" \
  -Dhermes-max-heap=67108864   # optional create-time MaxHeapSize (bytes); 0=default 3GiB
# Or per-instance: engine.create(id, .{ .max_heap_size = 64 * 1024 * 1024 })
# setMemoryLimit(...) still returns false on Hermes.

# Default backend still QuickJS-NG
zig build test-engine
```

No CI job runs these backends yet (manual / optional).

### Escargot threading build requirements

Vendor Escargot must be built with threading enabled. Required CMake flags:

```bash
cmake ... -DESCARGOT_THREADING=ON -DESCARGOT_TLS_ACCESS_BY_PTHREAD_KEY=ON \
  -DCMAKE_BUILD_TYPE=Release -DESCARGOT_ENABLE_SHELL=ON \
  -DESCARGOT_LIBICU_SUPPORT=OFF -DESCARGOT_FORCE_TLS_DIALECT_GNU2=ON
```

Supported threading configuration: `ENABLE_THREADING`, `ENABLE_TLS_ACCESS_BY_PTHREAD_KEY`, and `GC_THREAD_ISOLATE` must be present so `Globals::supportsThreading()` is true. Link Escargot with `-fno-lld` / GNU2 TLS so Zig does not hit TLSDESC failures on this pin.


## Remaining skips (engine / API limits)

- **Escargot mid-script interrupt — permanent**: no hook in `EscargotPublic.h` (this pin)
- **`setMemoryLimit` — permanent false** both backends; Hermes **create-time** max heap via Zig `EngineConfig.max_heap_size` or `-Dhermes-max-heap=N` (bytes; 0=default 3GiB). **`jsbay_engine_create_with_options`** exposes create-time `max_heap_size` (Hermes); plain `create` leaves 0. `set_memory_limit` still false on spike.
- **User `requestInterrupt`**: spike returns **false** (`supportsMidScriptUserInterrupt()==false`); Hermes mid-script remains stop/destroy only. `runtime_control_tests` not imported on spike.
- **`getMemoryUsage` soft stats** (Escargot `Memory::heapSize`/`totalSize`; Hermes `instrumentation().getHeapInfo`)
- Hermes stop/destroy: soft `watchTimeLimit` + `softRearmHermesStopAfterHost` + idle drain
- Escargot ET+host: **same-thread only**; `skipEscargotEtHost` — diminishing returns vs per-ET Context
- Escargot DestroyDefer (2): bdwgc ABRT — not cheap
- Hermes `ArrayBuffer.resize` — **permanent Skip**
- inspector / CDP; CJS bytecode cache (QJS-only); Hermes ESM beyond TLA; native_handle class_id

## Capability snapshot (vs QuickJS-NG; **not a production tag** / diminishing returns)

**Near QuickJS experience (usable spike main paths)**
- eval / value / object_ops / Promise / text CJS / host throw / native_handle (method + finalize)
- Hermes: engine_thread contracts including destroy-defer, soft interrupt, bind_sync, exotic TypedArray copy
- Escargot: THREADING smoke, same-thread host, ESM ModuleLoader, basic buffers
- Both: `runGc` + soft `getMemoryUsage` (observation-only; not QuickJS malloc layout)
- Hermes: create-time heap cap via `EngineConfig.max_heap_size` / `-Dhermes-max-heap` / `jsbay_engine_create_with_options.max_heap_size` (not runtime `setMemoryLimit`)
- Spike: `requestInterrupt` returns `false` (no mid-script claim)

**Hard gaps (accept or switch engines before a production tag)**
- Escargot: no mid-script interrupt; ET×host cannot cross threads (needs per-thread VM)
- Both: no runtime `setMemoryLimit` (Hermes create-time MaxHeapSize only; Escargot has no cap); no inspector/CDP; no QuickJS-shaped CJS bytecode cache
- Hermes: no `ArrayBuffer.resize`; ESM is a shim, not native module codegen
- Escargot DestroyDefer / precise weak: bdwgc limits

**Assessment**: cheap Skip→pass work on this spike is at **diminishing returns**; remaining gaps are mostly upstream or architectural.
