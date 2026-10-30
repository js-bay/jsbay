# Escargot / Hermes — 生产缺口排序（相对 QuickJS-NG / JSC）

以 `docs/capability.md` 为事实源。本表按对嵌入宿主的影响排序。

## Must（阻塞「可当生产引擎」）

| 缺口 | 影响 | 落点 | 状态 |
|------|------|------|------|
| CJS / `require` | 宿主脚本/bundle 主路径 | `src/script/cjs.zig`，backend `evalValue` + `makeNativeFunction` | **本轮已接文本路径**；无 QJS 形 bytecode CJS cache |
| `errors.throwError` / host 抛错 | native 回调 `try/catch` | `src/value/errors.zig`，`*Backend.throwError` → `*_throw` | **本轮已接**（pending_throw；kind 暂不进桥） |
| Hermes host-throw 稳定 | `NativeResult.err` / CJS missing-module / value `.err` | `libhermes_bridge.so` + `throw jsi::JSError` | **本轮已稳**（共享 libstdc++/libgcc_s；相关测已解 Skip） |
| `native_handle`（opaque+call+finalize+method） | SDK / 宿主可调用对象 | `*/native_handle.zig` + ExtraData/NativeState；MethodBox `*_dup` on setMethod | **本轮已绿**（Hermes+Escargot method this-binding smoke）；finalize teardown-forced |
| thick C ABI / engine_thread 契约 | 多实例 / 宿主线程模型 | smoke + **全套**；Hermes hostInstall/destroy-defer/nested/filename/after-stop **全绿**；Escargot host/dispatch 仍 Skip（Context 跨线程 AtomicString/GC SEGV；已收窄 same-thread only，无 SEGV 路径） | **部分**；THREADING 已开；Escargot ET+host = diminishing returns |
| 堆上限 / interrupt | 资源护栏 | runtime_control 对等 | **部分**：Hermes **stop/destroy** mid-script OK；**用户 `requestInterrupt` 两边都不保证 mid-script**（Escargot 永久无 hook；Hermes 故意不 arm sticky asyncTrigger）；**`setMemoryLimit` 永久 false**；Hermes create-time MaxHeapSize（Zig/build，非 C create）；软 `getMemoryUsage` |

## Should（接近 QuickJS/JSC 体验）

| 缺口 | 落点 |
|------|------|
| Hermes Promise rejection tracker | **本轮已接**：`HermesInternal.enablePromiseRejectionTracker` + drain 后 flush；module-shim throw 走 `hermes_report_unhandled_rejection` |
| Hermes ESM 剩余缺口 | **TLA 本轮已解**（async wrapper + awaitThenable）；sticky-fail + JSON attributes 已解；其余 shim 限制仍在 |
| Hermes `object_ops` | **本轮**：suite 绿；**destroy-during-trap 已解**（`api_bind.spikeInstall`） |
| buffer copy / transferable | **本轮**：C `copyBuffer` 已导入；两边 exotic-getter 绿；**Hermes `ArrayBuffer.resize` 永久 Skip**（无 native `.resize`；polyfill 无法更新 TA internal slots） |
| inspector / CDP | 长期；QuickJS-NG 才有 debugger hooks |

## Later

| 缺口 | 说明 |
|------|------|
| Escargot 磁盘 bytecode | Public API 无 blob |
| Hermes async/async-gen fixtures | 当前构建裁掉 |
| GC-precise weak/external | 现 teardown-forced |
| Escargot interrupt（永久） | `EscargotPublic.h` / `EscargotPublic.cpp` 无 interrupt / ExecutionTimeLimit / async-break API（本 pin 全库 rg 零命中）；仅能在 job/host 边界近似 |
| 两边 `setMemoryLimit`（永久 false） | Escargot 无 cap API；Hermes **无运行时 set** — 改用创建时 `EngineConfig.max_heap_size` / `-Dhermes-max-heap` → `GCConfig.MaxHeapSize` |
| Hermes create-time MaxHeapSize | **已接**：`hermes_runtime_new(max)` + `EngineConfig` + **`js_bay_engine_create2`**；`0` → `-Dhermes-max-heap` → 3GiB |
| `requestInterrupt` 诚实 | spike **返回 false**（`supportsMidScriptUserInterrupt`）；stop/destroy 仍可 mid-script（Hermes） |
| 新鲜 clone 重建脚本 | `scripts/rebuild-{icu,hermes,escargot}-install.sh` |
| `getMemoryUsage` 软统计 | **已接**：非 QJS 形字段；`malloc_size`≈heap/allocated；`setMemoryLimit` 仍拒绝 |
| CI 矩阵 + ABI 冻结 | 生产标签前提 |

## 验证

```bash
export JSBAY_LIBSTDCXX=/home/box/.local/gcc-root/usr/lib/gcc/x86_64-linux-gnu/14/libstdc++.a
export JSBAY_ICU_LIB_DIR=/workspace/jsbay-dual-spike/vendor/icu-prefix/lib
zig build test-engine -Dbackend=escargot -Dlibstdcxx="$JSBAY_LIBSTDCXX"
zig build test-engine -Dbackend=hermes -Dlibstdcxx="$JSBAY_LIBSTDCXX" -Dicu-lib-dir="$JSBAY_ICU_LIB_DIR"
```

安装前缀已在 `vendor/{escargot,hermes}-install`；改 Escargot bridge 后重编 `.o`；改 Hermes bridge 后重编 `libhermes_bridge.so`（勿再把 `.o` 链进 Zig）。

### Escargot mid-script interrupt — 永久缺口（证据）

本 pin `vendor/escargot-install/include/EscargotPublic.h` 与 `vendor/escargot/src/api/*`：
- **无** `interrupt` / `Interrupt` / `ExecutionTimeLimit` / `asyncBreak` / `shouldStop` 符号
- 公开面仅有 `Memory::gc` / `heapSize` / `totalSize` / `setGCFrequency`、Evaluator、VMInstance Promise hooks
- 对比 Hermes：`IHermes::asyncTriggerTimeout` + `watchTimeLimit` + bytecode `AsyncBreakCheck`
结论：无法在不改上游 Escargot 的前提下实现 mid-script `requestInterrupt`；`skipSpikeNeedsNativeInterrupt` 永久。

### Skip 分类（简表）

| 类 | Hermes (~30) | Escargot (~61) |
|----|--------------|----------------|
| **永久** | resize×3；CJS bytecode cache；spike-wide（dataview/exception/engine/cjs）；transfer 紧 cap；ESM 构建裁剪 | EtHost×24（Context 线程亲和）；NativeInterrupt×5；DestroyDefer×2（bdwgc ABRT）；bytecode 无 blob；同上 spike-wide |
| **本轮已 peel** | （上轮）destroy-defer/nested/filename/after-stop | after-stop / nested / filename-throw；memory smoke |
| **可 peel 但非廉价** | 无剩余廉价项 | DestroyDefer 需大改生命周期；EtHost=per-ET Context |

### 本轮验证（2026-10-31 Asia/Shanghai）

- Escargot: **491 pass / 61 skip / 0 fail**（+4：UnlessGreen 中 after-stop/nested/filename + memory smoke；DestroyDefer 仍 Skip）
- Hermes: **531 pass / 30 skip / 0 fail**（create-time MaxHeapSize smoke 已计；resize 永久；`setMemoryLimit` 仍 false）
- **diminishing returns**：Escargot ET+host / interrupt / DestroyDefer；Hermes resize / setMemoryLimit — 再 peel 需上游或大 refactor

