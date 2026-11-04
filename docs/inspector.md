# Inspector

## CDP Inspector

The optional CDP integration uses the independent `libs/inspector` package. `src/inspector/` supplies engine operations; `libs/inspector_transport` can provide the bundled HTTP/WebSocket server. Their standalone transport and package contracts are documented with those packages.

Build the demo and open its advertised target in Chrome DevTools:

```sh
zig build -Dbackend=quickjs_ng
./zig-out/bin/inspector-demo-quickjs_ng --port 9229
```

Add `localhost:9229` in `chrome://inspect`, then select the target. A port of zero asks the operating system to choose a port; query `boundPort` after startup.

The Zig facade exposes `start`, `startWithTransport`, `stop`, and `dropInstance`. Start and stop on the instance owner thread. `start` requires the bundled transport and returns `UnsupportedFeature` when `-Dinspector-transport=false` is selected. The C `jsbay_engine_inspector_start` API returns `false` for ownership, lifecycle, configuration, or startup failure.

Hosts may supply their own transport through `startWithTransport`. The generic transport callback, ownership, and shutdown contract belongs to [the Inspector package](../libs/inspector/readme.md). This engine integration must receive session closure so it can release engine-owned Inspector state.

## Compatibility limits

JS Bay implements a subset of CDP for an embedded JavaScript engine. It has no DOM, CSS, Page, Network, or browser tracing subsystem. `/json/protocol` and `Schema.getDomains` are the exact advertised surface for the running build. The [support manifest](../libs/inspector/src/protocol-support.json) is the source of generated discovery data; advertised commands can still support only a subset of optional parameters.

- Runtime evaluation, function calls, console events, and object inspection support limited parameters. CDP object handles retain engine values until released or the session closes; property behavior differs by backend.
- QuickJS and QuickJS-NG can wait for Promises while the host keeps driving its event loop. Closing Inspector cancels its waits, not application Promises. JSC does not advertise this capability.
- Exception events cover observable evaluation and asynchronous boundaries, not a complete engine-wide trace. Locations and stacks can be incomplete.
- QuickJS-NG advertises a partial execution CDP `Debugger` domain. Classic QuickJS advertises only `Debugger.enable`, `Debugger.disable`, `Debugger.getScriptSource`, and `Debugger.setAsyncCallStackDepth`, with `Debugger.scriptParsed`; it does not advertise breakpoints, pause control, stepping, or paused-frame evaluation. JSC uses Safari Web Inspector, not CDP Debugger. See [Backend domain matrix](#backend-domain-matrix). Raw bytecode without source identity cannot provide reliable attribution.
- QuickJS-family CPU profiles are interrupt samples from a bounded window. Heap snapshots are a custom bounded graph—see [HeapProfiler](#heapprofiler-not-chrome-memory) below; do not treat them as Chrome Memory.
- `Performance.getMetrics` is pull-only. `Timestamp` is monotonic seconds and QuickJS-family heap accounting is not process RSS. After `Performance.enable`, builds with supported thread CPU accounting also report `JSBayExecutionCPUTime`, which measures JavaScript execution attributed to that engine instance; do not treat it as process CPU time. Configuration changes are acknowledged after an ordinary owner turn applies them, so changes requested during a debugger pause wait for execution to resume. Session closure stops measurement at the next owner execution boundary.

Queues and retained diagnostic state are bounded. Slow or disconnected clients can lose queued events. A successful transport send only means the transport accepted a message. These limits protect the owner thread; they do not bound arbitrary host callbacks.

## HeapProfiler (not Chrome Memory)

**Hosts must not treat HeapProfiler output as a complete Chrome DevTools Memory / `.heapsnapshot`.**

The advertised surface is:

- commands `HeapProfiler.collectGarbage` and `HeapProfiler.takeHeapSnapshot`
- events `HeapProfiler.addHeapSnapshotChunk` and, when `reportProgress` is true, `HeapProfiler.reportHeapSnapshotProgress`

`HeapProfiler.collectGarbage` requests an owner-thread collection pass and returns an empty result. `HeapProfiler.takeHeapSnapshot` returns a custom `jsbaySnapshot` object. The same metadata is embedded in the raw snapshot as `snapshot.jsbaySnapshot`; clients that persist chunks should retain it with the raw graph. Before assuming completeness, read at least `complete`, `truncated`, `retainedSizeSupported`, and `omittedNodes` (related fields such as `omittedEdgeLabels`, `edgeCoverage`, and `propertyNamePrecision` further describe what was dropped). Retained-size measurement is not supported. Chunks carry a bounded partial reference graph, not a full heap dump.

Not implemented (expect method-not-found / not advertised):

- `HeapProfiler.getObjectByHeapObjectId`
- heap sampling (`startSampling`, `stopSampling`, `getSamplingProfile`, and related commands)

Building with `-Dheap-snapshot=false` keeps the public symbols but `takeHeapSnapshot` returns an unsupported error on QuickJS-family builds; discovery still advertises `collectGarbage`. JSC advertises `collectGarbage` but not heap snapshots over CDP.

## Backend domain matrix

Authority for what a running build advertises is `Schema.getDomains` and the support manifest [`libs/inspector/src/protocol-support.json`](../libs/inspector/src/protocol-support.json). Advertised commands can still support only a subset of optional parameters.

| Area | `quickjs` | `quickjs_ng` | `jsc` | `escargot` / `hermes` (spike) |
| --- | --- | --- | --- | --- |
| CDP `Debugger` | Non-execution subset (enable/disable/source retrieval/async stack; no breakpoints or pauses) | Partial execution support (enable/pause/breakpoints/step family in the manifest) | Not CDP Debugger; use [Safari Web Inspector](#safari-web-inspector) | Not advertised (inspector out of spike scope) |
| CDP `Runtime` / `Profiler` / `Performance` | Partial | Partial | Partial Runtime + Performance; no Profiler and no heap snapshots | `Runtime` + `Performance` + `Schema` only |
| CDP `HeapProfiler` | `collectGarbage`, bounded `takeHeapSnapshot`, chunk and optional progress events | Same | `collectGarbage` only | Not advertised |
| Safari Web Inspector | No | No | Supported JSC builds only | No |

Production hosts that fix `-Dbackend=quickjs` can retrieve source identity through the limited CDP Debugger subset, but source breakpoints and `debugger;` pause over CDP require `quickjs_ng`. Prefer `quickjs_ng` when execution debugging is required, or use the Safari path on JSC. Escargot/Hermes spike builds keep a minimal Schema surface and do not claim CDP Debugger or HeapProfiler readiness.

## Build options

`-Dinspector=false` disables CDP and source-debugging hooks. `-Dinspector-transport=false` keeps host-provided CDP transport support while omitting the bundled HTTP/WebSocket entry. `-Dheap-snapshot=false` omits QuickJS-family heap snapshots while retaining CDP garbage collection. The bundled network entry is unavailable on Windows. These switches do not remove public C ABI symbols.

## Safari Web Inspector

On supported JSC builds, call `jsc_remote_inspector.startAndEnable` after creating the instance and before scripts that need initial breakpoints run. The supplied name appears in Safari's Develop menu. The public `jsc_remote_inspector` namespace is empty on other backends, so shared Zig code must guard this call with a compile-time backend condition.

This path depends on platform JavaScriptCore symbols. It does not turn JSC into the CDP source debugger and it is not enabled by the CDP build option.

## Lifetime

Inspector retains non-primitive values exposed as CDP `objectId`s so DevTools can inspect them later. Stopping the Inspector or destroying the engine releases that state on the owner thread. Release CDP objects and object groups when a host owns the client protocol; do not retain an inspector handle after instance destruction.

## Protocol maintenance

The support manifest pins the upstream protocol commit and input hashes. Generate discovery JSON from those inputs:

```sh
node scripts/generate-cdp-protocol.mjs --source-root PROTOCOL_JSON_DIRECTORY
node scripts/generate-cdp-protocol.mjs --source-root PROTOCOL_JSON_DIRECTORY --check
```

The input directory must contain `js_protocol.json` and `browser_protocol.json`. `--fetch` retrieves pinned sources explicitly; an offline check requires `--source-root`. Do not keep another handwritten command inventory. Engine CDP integration tests, discovery tests, and Inspector package tests define behavior; passing one backend or protocol test does not prove compatibility with every DevTools frontend.
