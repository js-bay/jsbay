# Escargot / Hermes spike — 多轮对抗 Review

- **范围**：`/workspace/jsbay-dual-spike`，`-Dbackend=escargot|hermes` 生产填充树
- **姿态**：敌意 PR reviewer（正确性 / ABI 诚实 / 可复现 / 合入风险）
- **时区**：2026-10-31 Asia/Shanghai
- **门禁快照**（review 前最近绿）：Escargot **491 / 61 / 0**；Hermes **531 / 30 / 0**
- **本轮落地的诚实修复**：见文末「已修」

---

## Round 1 — Correctness / UB

| ID | 严重度 | 发现 | 证据 | 建议 |
|----|--------|------|------|------|
| R1-1 | **blocker**（合入主线前） | Escargot Context **线程亲和**：ET 跑起来后跨线程 `hostInstall` / AtomicString / GC → SEGV；已用 same-thread refuse + `skipEscargotEtHost`（~24）盖住，**不是**修好了 | `src/abi/spike_host_abi.zig:6-7,45`；`src/runtime/engine_thread.zig:252`；`skipEscargotEtHost` in `engine_thread_tests.zig:552` | 合入主线前必须把「Escargot ET+host = same-thread only / 跨线程 UB」写进对外 embedding 红线；勿把 gated pass 读成 thick C ABI 对等 |
| R1-2 | **blocker**（产品语义） | 公共 **`requestInterrupt` 在 spike 上不保证 mid-script 中止**，但返回 `true`。Escargot：无 Public interrupt hook，bit 无人在 eval 中轮询。Hermes：故意不在 user interrupt 路径调 `asyncTriggerTimeout`（sticky Timeout 毒后续 eval）；mid-script 仅 stop/destroy → `requestStopInterrupt` | `runtime_control.zig` `requestInterrupt`；Escargot 无 `JS_SetInterruptHandler` 对等；`all_tests.zig:90-92` **不**导入 `runtime_control_tests`（含 `while(true)` 中止套件） | 文档已补强；合入前考虑 Escargot 对 `requestInterrupt` 返回 `false`，或 Hermes 在 eval 出口统一 drain + 谨慎 arm（非廉价） |
| R1-3 | **major** | Hermes **sticky** `asyncTriggerTimeout`：host 返回后若不 `softRearmHermesStopAfterHost` / drain，后续 `hostDestroy();42` 等直接 eval 被毒 | `runtime_control.zig:172-178`；`spike_host_abi.zig:232-233` | 任何新 host 出口必须接 softRearm；缺接 = 隐蔽回归（测名：destroy-defer / after-stop） |
| R1-4 | **major** | `native_handle` / External **finalize teardown-forced**（`pending_finals`）；非 GC-precise。Escargot GC 路径曾 UAF → 强制 teardown | `hermes_bridge.cpp` / `escargot_bridge.cpp` `pending_finals`；`*/native_handle.zig` 头注释 | 对外勿宣称弱引用/GC finalizer 对等 QJS；capability 已写 partial — 保持 |
| R1-5 | **major** | Escargot **DestroyDefer**（destroy-from-host during direct eval）bdwgc **ABRT** — Skip 挡崩溃，不是绿 | `skipEscargotDestroyDefer`；`engine_thread_tests.zig:1705,1961` | 永久缺口；禁止 peel `UnlessGreen` 一刀切 |
| R1-6 | **minor** | Hermes transfer **polyfill**：`detachArrayBuffer` 后 source `byteLength` 可能非 0；测里对 Hermes 放宽 | `hermes_bridge.cpp` transfer polyfill；`buffers_transfer_tests.zig:58-59` | capability 曾写「Transfer: no」——已改为 polyfill + quirk（见已修） |
| R1-7 | **minor** | Hermes bytecode 错栈缺 filename → **SkipZigTest**（可能掩盖回归） | `bytecode_tests.zig:95-98` | 可接受为 partial；勿当 pass |
| R1-8 | **minor** | Hermes 无 `ArrayBuffer.resize`；三测永久 Skip | `buffer_copy_contract_tests.zig:107,144,180` | 已标永久；勿 polyfill 假 resize |

---

## Round 2 — API / ABI 诚实度

| ID | 严重度 | 发现 | 证据 | 建议 |
|----|--------|------|------|------|
| R2-1 | **major** | **`setMemoryLimit` 永远 false**（spike）；Hermes 堆顶是 **create-time** `GCConfig.MaxHeapSize`，且仅 Zig `EngineConfig.max_heap_size` / `-Dhermes-max-heap`；**`js_bay_engine_create` 无此参数** | `runtime_control.setMemoryLimit`；`types.EngineConfig.max_heap_size`；`include/js_bay.h:42,47`；`c_api.zig` `cApiEngineConfig` 未传 heap | 文档已写；C ABI 若要对称需 `create2`/options 结构体（范围外） |
| R2-2 | **major** | `getMemoryUsage` 软统计 **字段挪用**（`malloc_size`←heap/allocated），非 QJS 形；宿主若按 QJS 语义做泄漏判定会误判 | `runtime_control.getMemoryUsage` escargot/hermes 分支 | 保持「观测用」；SDK 注释警告 |
| R2-3 | **major** | capability 表曾 **自相矛盾**：ArrayBuffer 行写 Transfer: no，buffer 行写 native/polyfill green | `capability.md` Escargot L29 vs L43；Hermes L66 vs L80 | **已修** Transfer 表述 |
| R2-4 | **major** | Hermes **ESM = host shim**（非原生 module codegen）；CJS = 文本路径，无 QJS bytecode CJS cache — 表写 **yes** 易过读 | `capability.md` CJS/ESM；`hermes_esm.cpp` | ESM 已 partial；CJS 建议注「text-only」更醒目（已有 notes） |
| R2-5 | **major** | engine_thread **矩阵**：Hermes 近全绿；Escargot smoke + same-thread host，大量 EtHost/Interrupt/DestroyDefer Skip — 「full suite imported」≠「full suite green」 | `all_tests.zig` 导入 ET；skip helpers | 对外用 Skip 分类表（production-gaps），勿只报 pass 数 |
| R2-6 | **minor** | `runtime-limits.md` / embedding 曾按 QJS 口吻描述 `requestInterrupt` mid-script | `docs/runtime-limits.md` | **已修** spike 免责声明 |
| R2-7 | **minor** | production-gaps Hermes 计数行残留「见下轮」过时语气 | 原 L69 | **已修** |

---

## Round 3 — Build / CI / 可移植性

| ID | 严重度 | 发现 | 证据 | 建议 |
|----|--------|------|------|------|
| R3-1 | **blocker**（新鲜 clone） | **`vendor/{escargot,hermes}-install`、`icu-prefix` gitignored**；无预构建产物 → 仅 submodule 源不够跑 `-Dbackend=escargot|hermes` | `.gitignore`；`capability.md` Local build；`build.zig.zon` **paths 不含** escargot/hermes/icu | 文档化「必须本地重建 prefix」脚本；或 CI artifact；勿声称 `zig build -Dbackend=hermes` 开箱即用 |
| R3-2 | **major** | Escargot 需 **THREADING + GNU2 TLS** 重建：`-DESCARGOT_THREADING=ON`、`TLS_ACCESS_BY_PTHREAD_KEY`、`FORCE_TLS_DIALECT_GNU2`；Zig **`use_lld=false`**（仅 test 可执行文件一处） | `capability.md` THREADING 段；`build.zig:322` | 把 cmake/ninja 完整命令收成可复制脚本；核对 lib 目标是否也需 `use_lld=false` |
| R3-3 | **major** | Hermes 桥必须是 **`libhermes_bridge.so`**（与 hermesvm 共 EH）；Zig 链 **不能** 用 libc++；要 `JSBAY_LIBSTDCXX` + `JSBAY_ICU_LIB_DIR` | `build.zig` `addHermesSources`；`capability.md` g++ `-shared` 配方 | 新鲜环境缺 g++-14 / ICU prefix 即挂 — 写工具链矩阵 |
| R3-4 | **major** | `build.zig.zon` 包名 `.js_bay`，**不发布** spike vendor；fingerprint `0x2bdd844411571869` 与 QJS 主路径共享 | `build.zig.zon` | spike 合入勿污染默认 backend；zon paths 保持不含 install 树 |
| R3-5 | **minor** | bytecode fingerprint **不含** `hermes_max_heap`（合理：非 QJS bytecode） | `bytecodeFingerprint` 签名 | 无需改；create-time heap 不进 fingerprint |
| R3-6 | **minor** | 源 pin SHA 与 submodule HEAD **一致**（本机核对） | escargot `ffd9b77a…`；hermes `9a51f48d…` = `capability.md` 表 | 保持；bump 源必须重编 install |

---

## Round 4 — Product / 合入主线风险

| ID | 严重度 | 发现 | 证据 | 建议 |
|----|--------|------|------|------|
| R4-1 | **blocker** | 工作树名 `jsbay-dual-spike` vs 包/API `js_bay` / 品牌 **JS Bay** — spike 合入主仓需统一叙事，避免第二产品名 | `build.zig.zon` `.name = .js_bay`；`include/js_bay.h`；`README.md`；cwd | 合入用「experimental backend」标签；保留 `js_bay_*` ABI |
| R4-2 | **major** | 默认 README 仍强调 QJS/JSC；spike 一节短 — **好**。但 capability「生产就绪快照」易被销售读成可打生产标签 | `capability.md` 中文快照；`README` Experimental | 标题加「非生产 / diminishing returns」；主仓 merge 门槛：interrupt + ET 诚实矩阵 |
| R4-3 | **major** | `THIRD_PARTY_NOTICES.md` 已有 Escargot（LGPL 注意）、Hermes、ICU — **发布 Hermes/Escargot 链接产物必须随带 LICENSE** | `THIRD_PARTY_NOTICES.md` Samsung Escargot / Meta Hermes / ICU | Escargot LGPL 合规流程是合入 blockers 之一 |
| R4-4 | **minor** | `assets/brand-icons` 含 hermes-logo 等 — 注意上游商标使用 | `assets/brand-icons/hermes-logo.svg` 等 | 文档 ATTRIBUTION；对外物料慎用 |
| R4-5 | **minor** | 无 CI job 跑 escargot/hermes（capability 自陈） | `capability.md` 「No CI job…」 | 合入前至少 nightly 手动/可选 job，否则主线绿 ≠ spike 绿 |

---

## 已修（本轮廉价诚实修复）

1. `src/runtime/runtime_control.zig`：修复 `` `setMemoryLimit` `` 双反引号；`requestInterrupt` 文档注释写明 spike 语义  
2. `docs/capability.md`：ArrayBuffer Transfer 矛盾（native / polyfill）；heap/interrupt 行区分 user vs stop；C ABI 无 `max_heap_size`；spike 未跑 `runtime_control_tests`  
3. `docs/production-gaps.md`：过时「见下轮」；interrupt 诚实表述  
4. `docs/runtime-limits.md`：spike 下 `requestInterrupt` / MaxHeapSize / `set_memory_limit` 免责声明  

**未做**（非廉价 / 上游）：Escargot mid-script hook、EtHost per-thread VM、Hermes user-interrupt arm、`js_bay_engine_create` 扩展、DestroyDefer、resize。

---

## Top blockers（合入 / 对外宣称前）

1. 新鲜 clone **无法** 仅靠 submodule 复现 spike 构建（缺 install/ICU + 工具链）  
2. 公共 **`requestInterrupt` 语义在 spike 上过承诺**（返回 true ≠ mid-script 停）  
3. Escargot **跨线程 ET+host = UB**（Skip 掩盖，非修复）  
4. Escargot **LGPL** + 无 CI → 发布与合入流程未就绪  
5. C ABI **`set_memory_limit` / create** 与 Zig create-time MaxHeapSize **不对齐** — 嵌入宿主走 C 则「堆顶」不可达  

---

## 结论

Spike 树在「廉价 Skip→pass」上已 **diminishing returns**；对抗视角下最大风险是 **诚实度与可复现**，不是再 peel 几个测。合入 `js-bay` / `jsbay` 主线前：冻结能力边界、补重建脚本/CI、修或明确降级 `requestInterrupt` 返回值语义、处理 Escargot LGPL。

---

## 对抗修复续轮（2026-10-31 Asia/Shanghai）

| 项 | 状态 |
|----|------|
| R3-1 重建脚本 | **落地** `scripts/rebuild-{icu,escargot,hermes}-install.sh` + capability/embedding 链接 |
| R1-2 requestInterrupt | **落地** spike 返回 `false`；`supportsMidScriptUserInterrupt`；ET after-stop-bits 测对齐 |
| R1-1 Escargot ET×host | **保持硬拒绝** + embedding 红线文档 |
| R2-1 C ABI max_heap | **落地** `js_bay_engine_create2` + header 注释；`set_memory_limit` 注明 spike false |
| Android 门禁 | **可达（2026-10-31 Asia/Shanghai）**：NDK r27c + AVD `jsbay_api34`；TCG `-accel off`。QJS / **Escargot** / **Hermes** x86_64：各自 Android install 前缀 + Zig library-only + NDK `.so`；模拟器 C ABI evaluate smoke（`1+2`）均 **PASS**（`jsbay-{qjs,escargot,hermes}-android-smoke-ok`）。`check-c-abi` 对两引擎 `.so` **PASS**（`resolvePathCmd` 绝对路径 + `@export` create2）。全量 gated suite **未**在 TCG 上跑。详见 `docs/android-box-status.md`。 |
