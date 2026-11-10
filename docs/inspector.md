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
- Non-JSC backends expose CDP execution debugging through native location hooks or a native protocol agent. JSC uses Safari Web Inspector. See [Backend domain matrix](#backend-domain-matrix) for the supported domains. Raw bytecode without source identity cannot provide reliable attribution.
- QuickJS-family CPU profiles are interrupt samples from a bounded window. Heap snapshots are a custom bounded graph—see [HeapProfiler](#quickjs-family-heapprofiler) below; do not treat them as Chrome Memory.
- `Performance.getMetrics` is pull-only. `Timestamp` is monotonic seconds and QuickJS-family heap accounting is not process RSS. After `Performance.enable`, builds with supported thread CPU accounting also report `JSBayExecutionCPUTime`, which measures JavaScript execution attributed to that engine instance; do not treat it as process CPU time. Configuration changes are acknowledged after an ordinary owner turn applies them, so changes requested during a debugger pause wait for execution to resume. Session closure stops measurement at the next owner execution boundary.

Queues and retained diagnostic state are bounded. Slow or disconnected clients can lose queued events. A successful transport send only means the transport accepted a message. These limits protect the owner thread; they do not bound arbitrary host callbacks.

## QuickJS-family HeapProfiler

**Hosts must not treat HeapProfiler output as a complete Chrome DevTools Memory / `.heapsnapshot`.**

QuickJS-family builds advertise:

- commands `HeapProfiler.collectGarbage` and `HeapProfiler.takeHeapSnapshot`
- events `HeapProfiler.addHeapSnapshotChunk` and, when `reportProgress` is true, `HeapProfiler.reportHeapSnapshotProgress`

`HeapProfiler.collectGarbage` requests an owner-thread collection pass and returns an empty result. `HeapProfiler.takeHeapSnapshot` returns a custom `jsbaySnapshot` object. The same metadata is embedded in the raw snapshot as `snapshot.jsbaySnapshot`; clients that persist chunks should retain it with the raw graph. Before assuming completeness, read at least `complete`, `truncated`, `retainedSizeSupported`, and `omittedNodes` (related fields such as `omittedEdgeLabels`, `edgeCoverage`, and `propertyNamePrecision` further describe what was dropped). Retained-size measurement is not supported. Chunks carry a bounded partial reference graph, not a full heap dump.

Not implemented on QuickJS-family builds (expect method-not-found / not advertised):

- `HeapProfiler.getObjectByHeapObjectId`
- heap sampling (`startSampling`, `stopSampling`, `getSamplingProfile`, and related commands)

Building with `-Dheap-snapshot=false` keeps the public symbols but `takeHeapSnapshot` returns an unsupported error on QuickJS-family builds; discovery still advertises `collectGarbage`. JSC advertises `collectGarbage` but not heap snapshots over CDP.

## Backend domain matrix

Authority for what a running build advertises is `Schema.getDomains` and the support manifest [`libs/inspector/src/protocol-support.json`](../libs/inspector/src/protocol-support.json). Advertised commands can still support only a subset of optional parameters.

| Area | `quickjs` | `quickjs_ng` | `jsc` | `escargot` | `hermes` |
| --- | --- | --- | --- | --- | --- |
| CDP `Debugger` | Partial execution support: source breakpoints, pause/resume, stepping, and frame evaluation | Same | Safari Web Inspector; CDP on Simulator through the [host bridge](#jsc-cdp-bridge) | Native location hooks; frame evaluation and stepping | Native CDP agent; frame evaluation and stepping |
| CDP `Runtime` / `Profiler` / `Performance` | Partial | Partial | Runtime + Performance | Runtime + Performance | Native Runtime + Profiler; shared Performance |
| CDP `HeapProfiler` | Collection and bounded snapshots | Collection and bounded snapshots | Collection | Collection | Native heap commands in the manifest |
| Safari Web Inspector | No | No | Supported JSC builds only | No | No |

`/json/protocol` and `Schema.getDomains` describe each backend's exact advertised surface. Escargot provides line breakpoints and top-frame evaluation; it does not advertise exception-pause or async-stack configuration. Hermes owns its Runtime and Debugger object handles, so frame evaluation and property inspection use the same native session. Hermes heap sampling and snapshots use its native agent rather than the QuickJS-family graph format. Backend availability and SDK packaging remain platform-specific.

QuickJS-family engines and Escargot step by executable source line. Within one frame, step over and step into skip remaining locations on the same line; step into still enters called functions. Explicit breakpoints and debugger statements override stepping, and Debugger.pause can interrupt a line-granular step loop. Step out stops at the first shallower native JavaScript location, including a caller's return expression. This may pause on the call line before an assignment completes, whereas V8 may advance to the next statement. A call's before/after locations can have identical coordinates; variable values and callee effects distinguish them. Async resumption does not synthesize caller frames. Step out from a native callback finishes the native call before stopping at its first shallower JavaScript location.

QuickJS-family engines do not decode source locations while no breakpoint or stepping work is active. If the first breakpoint is added while a call is already running, returning from that call can pause once at the caller's call location even though execution has already entered the callee.

QuickJS-family paused-frame evaluation uses snapshots of local and closure bindings. Assignments to these bindings do not update the suspended frame, and `arguments` belongs to the evaluation function. If the program deletes the global `eval` binding or replaces it with an accessor, paused evaluation can fail or invoke that accessor while resolving the helper call.

Hermes journals source entries by native script id while debugging is enabled. Each entry is limited to 64 KiB, and the journal retains at most 128 entries and 4 MiB of source. `Debugger.getScriptSource` returns an explicit error for entries that exceed these bounds, unavailable bytecode sources, and dynamic scripts without an unambiguous source entry. Recompiling the same URL preserves each retained script id's own source.

Run `zig build test-cdp -Dbackend=<backend>` to exercise discovery, a source breakpoint, paused-frame evaluation, stepping, resume, and reconnect against a real Inspector process. Escargot and Hermes builds also require their native install prefixes and C++ dependencies. JSC source debugging follows the Safari path.

Rebuild native prefixes with `scripts/rebuild-escargot-install.sh` or `scripts/rebuild-hermes-install.sh` after changing their bridge sources, debugger patches, or build configuration. The scripts write a source digest into the install prefix; Zig rejects a missing or stale digest before linking. The scripts patch `ESCARGOT_SRC` or `HERMES_SRC` in place, so use a separate source copy when the pinned submodule must remain untouched.

## Mobile SDK access

Android, Apple, and Harmony SDKs expose owner-thread Inspector start and stop methods. Their listeners bind to app-local loopback. Android devices use `adb forward tcp:<host-port> tcp:<device-port>`; an iOS Simulator listener is reachable through the host's loopback interface. Physical iOS and Harmony devices require a forwarding transport to the returned app-local port.

Keep the engine on a dedicated owner thread or Worker so a debugger pause does not block the host that delivers control messages. See the [Android](../sdk/android/README.md#cdp-debugging), [Apple](../sdk/apple/README.md#cdp-debugging), and [Harmony](../sdk/harmony/README.md#cdp-debugging) SDK instructions. The same `tests/inspector/e2e.cjs --debugger-flow` contract runs against a forwarded mobile endpoint.

## Build options

`-Dinspector=false` disables CDP and source-debugging hooks. `-Dinspector-transport=false` keeps host-provided CDP transport support while omitting the bundled HTTP/WebSocket entry. `-Dheap-snapshot=false` omits QuickJS-family heap snapshots while retaining CDP garbage collection. The bundled HTTP/WebSocket transport supports loopback connections on Windows; consumers of its static library must link `ws2_32`. These switches do not remove public C ABI symbols.

## Safari Web Inspector

On supported JSC builds, call `jsc_remote_inspector.startAndEnable` after creating the instance and before scripts that need initial breakpoints run. The supplied name appears in Safari's Develop menu. The public `jsc_remote_inspector` namespace is empty on other backends, so shared Zig code must guard this call with a compile-time backend condition.

The `jsc-safari-demo` example owns its context on the main thread and keeps that thread's Apple `CFRunLoop` active for Web Inspector commands. It attaches the engine's automatic driver to that run loop rather than blocking it in `engine.runEventLoop`, uses deadline-driven callbacks for JavaScript tasks, and stops both loops before releasing the engine. A separate context owner thread is not covered by this example's debugger test.

Build the simulator example with `zig build safari-demo-build -Dbackend=jsc -Dtarget=aarch64-ios.14.0-simulator "-Dapple-sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)"`. With a simulator already booted, run `JSBAY_IOS_SIM_UDID=<booted-simulator> bash tests/apple-sdk/run-jsc-inspector-sim.sh zig-out/bin/jsc-safari-demo`. This checks the real Web Inspector protocol, including breakpoints, paused-frame evaluation, stepping, reconnection, and normal shutdown. It does not automate the Safari graphical interface.

The regression requires normal context teardown as well as successful debugger commands. A native JavaScriptCore shutdown crash fails the check; debugger command success alone does not establish runtime compatibility.

This path depends on platform JavaScriptCore symbols. It does not turn JSC into the CDP source debugger and it is not enabled by the CDP build option.

### JSC CDP bridge

`devtools/jsc-inspector-bridge` exposes a JSC target as a CDP endpoint for hosts that need the same client tooling as the other backends. The bridge runs as a separate host process, attaches to the WebKit Inspector Relay, and serves `/json` discovery plus a CDP WebSocket on loopback. The target keeps its Safari Web Inspector support and needs no extra code or build flags.

The bridge covers `Runtime` and `Debugger`: evaluation, property inspection, source breakpoints, paused-frame evaluation, stepping, resume, script sources, and console events. It adds the CDP fields the relay omits, including `debuggerId`, call-frame URLs, CDP scope types, and `exceptionDetails` for thrown evaluation results. Its [README](../devtools/jsc-inspector-bridge/README.md) lists the exact command and parameter mapping.

Supported path: iOS Simulator, using the relay socket reported by `RWI_LISTEN_SOCKET`. macOS is a gap: the macOS relay is reached through XPC mach services instead of a socket, and the Safari frontend service rejects third-party clients, so the bridge provides no macOS transport. Physical device support is unverified.

Known target gaps on the Simulator: JSC accepts `Debugger.setPauseOnExceptions` but does not deliver a pause for thrown exceptions or `debugger;` statements in the tested targets, block bindings appear in a separate scope, and column-granular breakpoints can resolve to the next executable statement. Breakpoint, stepping, and frame-evaluation flows pass.

### iOS 26.5 system JavaScriptCore teardown limitation

The iOS 26.5 Simulator runtime (23F77) has a known system JavaScriptCore limitation: after an Inspector frontend connects and detaches, normal context or VM teardown can terminate with `SIGTRAP` in `Inspector::JSGlobalObjectInspectorController`. The failure does not require Runtime or Debugger commands.

This runtime does not satisfy the normal-teardown requirement for Inspector compatibility. JS Bay uses the system JavaScriptCore framework and provides no workaround for this limitation. Physical iOS 26.5 compatibility is unverified.

## Lifetime

Inspector retains non-primitive values exposed as CDP `objectId`s so DevTools can inspect them later. Stopping the Inspector or destroying the engine releases that state on the owner thread. Release CDP objects and object groups when a host owns the client protocol; do not retain an inspector handle after instance destruction.

## Protocol maintenance

The support manifest pins the upstream protocol commit and input hashes. Generate discovery JSON from those inputs:

```sh
node scripts/generate-cdp-protocol.mjs --source-root PROTOCOL_JSON_DIRECTORY
node scripts/generate-cdp-protocol.mjs --source-root PROTOCOL_JSON_DIRECTORY --check
```

The input directory must contain `js_protocol.json` and `browser_protocol.json`. `--fetch` retrieves pinned sources explicitly; an offline check requires `--source-root`. Do not keep another handwritten command inventory. Engine CDP integration tests, discovery tests, and Inspector package tests define behavior; passing one backend or protocol test does not prove compatibility with every DevTools frontend.
