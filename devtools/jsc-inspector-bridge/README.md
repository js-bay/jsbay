# jsbay-inspector-bridge

`jsbay-inspector-bridge` exposes a JavaScriptCore target as a Chrome DevTools Protocol endpoint. It connects to the WebKit Inspector Relay, attaches to a JavaScript target, and serves CDP discovery plus a WebSocket endpoint on loopback.

The bridge runs outside the inspected process. The target only has to enable the system JSC remote inspector, for example with `JSGlobalContextSetInspectable`. No debugger code is linked into the host application, and Safari Web Inspector keeps working against the same target.

## Status

- iOS Simulator: supported. The bridge reads `RWI_LISTEN_SOCKET` from the booted simulator and attaches over the relay socket.
- macOS: not supported by this transport. The relay is reached through XPC mach services instead of a socket, and both `com.apple.webinspector` and `com.apple.webinspector.debugger` interrupt connections from processes without the private Web Inspector entitlement. Use Safari Web Inspector on macOS.
- iOS device: supported through a forwarder. A device exposes the relay as the lockdown service `com.apple.webinspector`, or as `com.apple.webinspector.shim.remote` over remote service discovery, instead of a socket. Open that service and pipe it to a loopback TCP port, then attach with `--socket tcp://host:port`. The inspected application must be running in the foreground on an unlocked device; a locked or backgrounded application still appears in the relay application list but reports no JavaScript target, and the bridge then fails with a discovery error.
- Only one target per bridge process. The first JavaScript target of the selected application is used.
- A client is detached when the inspected application exits: the relay reports the disconnect, the bridge closes every CDP session, and the process ends. Reconnect a client after the target has a JavaScript context again.
- One CDP client at a time. The bridge owns a single relay frontend sender, so a second client would share breakpoint, pause, and domain state with the first, and a `Debugger.disable` from either would affect both. The second WebSocket is closed when it opens; reconnect one frontend at a time.

## Usage

Build and run from this directory:

```sh
zig build
zig-out/bin/jsbay-inspector-bridge --socket "$RWI_LISTEN_SOCKET"
```

Options:

- `--socket <path>`: relay socket. Required for the simulator path. `tcp://host:port` attaches through a forwarder that exposes the relay on a TCP port.
- `--application <name>`: application name reported by the relay. Defaults to the newest process that reports a JavaScript target.
- `--target <title>`: JavaScript target title. Defaults to the first target.
- `--port <port>`: CDP port. `0` selects an ephemeral port.
- `--probe`: attach, enable `Runtime`, print the relay traffic, and exit.
- `--trace`: dump relay frames on stderr.

The command prints the discovery URL, for example `http://127.0.0.1:9229/json/list`. Point DevTools or a CDP client at that endpoint.

Typical simulator flow:

```sh
xcrun simctl spawn "$UDID" launchctl kickstart user/foreground/com.apple.webinspectord
xcrun simctl spawn "$UDID" /path/to/jsc-demo &
RWI_LISTEN_SOCKET="$(xcrun simctl spawn "$UDID" launchctl getenv RWI_LISTEN_SOCKET)"
zig-out/bin/jsbay-inspector-bridge --socket "$RWI_LISTEN_SOCKET" --application jsc-demo
```

Typical device flow. Keep the application in the foreground on an unlocked device, pipe the `com.apple.webinspector` lockdown service to a loopback TCP port with a forwarder, then attach through it:

```sh
zig-out/bin/jsbay-inspector-bridge --socket tcp://127.0.0.1:9380 --application jsc-demo
```

The relay reports applications by process name, which is the application's display or executable name rather than its bundle identifier. Pass the name the relay reports to `--application`.

The demo target in this repository builds for the simulator only. The device SDK ships TAPI stubs for `arm64e-ios` alone, and the Zig linker matches a stub by exact architecture, so an `arm64` device link resolves no system symbols; a device build comes from Xcode. The bridge does not depend on how the inspected app was built, so any device app that registers an inspectable JavaScript context works.

## Translation scope

Commands are forwarded to the relay with the CDP method and parameters, and relay notifications are copied to every attached CDP session. Command ids are rewritten per session so concurrent clients cannot consume each other's replies.

Forwarded domains:

- `Runtime`: enable, disable, evaluate, callFunctionOn, getProperties, releaseObject, releaseObjectGroup, discardConsoleEntries, getIsolateId.
- `Debugger`: enable, disable, breakpoints, resume, stepping, pause-on-exceptions, frame evaluation, script source, search, blackboxing, async stack traces, instrumentation breakpoints.

Enable and disable commands for other domains return an empty result so a general-purpose frontend can finish its handshake. Unsupported methods return JSON-RPC error `-32601`.

The bridge adds state that CDP clients require but the relay omits:

- `debuggerId` on `Debugger.enable`.
- `url` on paused call frames, resolved from recorded `Debugger.scriptParsed` notifications.
- CDP scope types: relay `nestedLexical` scopes become `block`, `globalLexicalEnvironment` becomes `script`, and the innermost `closure` scope becomes `local`.
- `result` instead of `properties` for `Runtime.getProperties`, and `exceptionDetails` for thrown evaluation results.
- `silent` on `Runtime.evaluate`, `Runtime.callFunctionOn`, and `Debugger.evaluateOnCallFrame`, mapped to the relay option that keeps a throwing evaluation from pausing the target.
- An empty `functionName` for the top-level script frame, which the relay reports as `global code`.
- `Debugger.setBreakpointsActive` is sent after `Debugger.enable`, because JSC does not pause at a resolved breakpoint until the debugger activates breakpoints.
- `Debugger.setPauseOnDebuggerStatements` is sent after `Debugger.enable`, because JSC only stops at a `debugger` statement once a frontend arms that switch. CDP has no equivalent command.
- `Runtime.executionContextCreated` with one synthetic context after `Runtime.enable`. JSC has a single context and never announces it, and CDP clients wait for the announcement before they evaluate. `contextId` and `uniqueContextId` are dropped from forwarded requests, and evaluation results carry that context id.
- A column offset on a breakpoint is dropped when the script spans more than one line, so the breakpoint resolves to the statement on the requested line instead of a later statement. A single-line script keeps the offset, where it is the only way to name a statement, and `Debugger.continueToLocation` keeps it because zeroing the column would move the target behind the position execution resumes from.
- A step out that returns to the end of the outermost statement reports the statement that made the call, matching other CDP engines.
- A `Debugger.resumed` notification also answers the oldest outstanding resume, step, or continue command, because the relay reports the notification and does not always answer the command itself. A relay reply that arrives afterwards is dropped as already answered.

## macOS

The macOS relay has no UNIX socket. `webinspectord` publishes only the `com.apple.webinspector` and `com.apple.webinspector.debugger` mach endpoints, and a third-party XPC client receives `Connection interrupted` from both services because the daemon checks for Apple's private Web Inspector entitlements. Producing a CDP endpoint for a macOS host therefore requires either a signed helper that holds those entitlements or an in-process debugger path that does not use the relay.

## Known fidelity differences

These come from the JSC target and its relay protocol rather than from the bridge:

- A step out that leaves a JavaScript callback which a native frame called resumes execution instead of pausing in the calling JavaScript frame. The relay reports `Debugger.resumed` and then no further pause, so there is no frame to report and the client waits until execution stops for another reason.
- `Debugger.pause` arms a pause for the next JavaScript statement. A target that is not running JavaScript, for example one whose only work happens in native code, reports no pause until script executes again.
- Breakpoints are statement granular, so two breakpoints that resolve to the same statement collapse into one and the relay rejects the second as an existing location.
- A URL breakpoint registered before the script it names has been parsed does not bind to that script: `Debugger.setBreakpointByUrl` reports no locations and the breakpoint never fires. A frontend that sets breakpoints before scripts load has to set them again after `Debugger.scriptParsed`.
- Console API calls are not visible. JSC reports console output to the console client the host application installs, and the relay receives nothing, so CDP frontends show no `Runtime.consoleAPICalled` events. Breakpoints, stepping, and evaluation are unaffected. A host that reports its console messages to the Web Inspector console client makes them available to the relay.
- Block-scoped bindings are reported in a separate `block` scope. Frontends that merge block bindings into the frame's local scope show fewer names in the local scope.
- A breakpoint offset inside a multi-line expression resolves to the start of the statement that contains it.
- Script metadata keeps the most recent 1024 scripts of a target that parses more than that, so an older script reports no URL and keeps no breakpoint column offset, like a script parsed before the bridge attached.

## Tests

```sh
zig build test
```

`zig build test` covers the binary plist codec, the relay UUID format, and the bridge state machine. The bridge tests pair a scripted relay with a recording frontend, so session lifecycle, reply routing, injected command ids, and merged scope properties run without a simulator. Tests that need a real target live in `tests/apple-sdk/run-jsc-bridge-sim.sh` and `tests/inspector/e2e.cjs`.

End-to-end checks against a simulator target live in `tests/apple-sdk/run-jsc-bridge-sim.sh` in the repository root. The script starts the demo and the bridge, runs the CDP debugger flow of `tests/inspector/e2e.cjs`, and skips the steps that describe behavior JSC cannot produce.
