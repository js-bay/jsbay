# jsbay-inspector-bridge

`jsbay-inspector-bridge` exposes a JavaScriptCore target as a Chrome DevTools Protocol endpoint. It connects to the WebKit Inspector Relay, attaches to a JavaScript target, and serves CDP discovery plus a WebSocket endpoint on loopback.

The bridge runs outside the inspected process. The target only has to enable the system JSC remote inspector, for example with `JSGlobalContextSetInspectable`. No debugger code is linked into the host application, and Safari Web Inspector keeps working against the same target.

## Status

- iOS Simulator: supported. The bridge reads `RWI_LISTEN_SOCKET` from the booted simulator and attaches over the relay socket.
- macOS: not supported by this transport. The relay is reached through XPC mach services instead of a socket, and both `com.apple.webinspector` and `com.apple.webinspector.debugger` interrupt connections from processes without the private Web Inspector entitlement. Use Safari Web Inspector on macOS.
- iOS device: not implemented. A device exposes the relay as a lockdown or remote service discovery service instead of a socket, and USB port forwarding cannot reach that service, so the device path needs its own tunnel. A tunnel that republishes the relay on a TCP port works with `--socket tcp://host:port`.
- Only one target per bridge process. The first JavaScript target of the selected application is used.

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
- An empty `functionName` for the top-level script frame, which the relay reports as `global code`.
- `Debugger.setBreakpointsActive` is sent after `Debugger.enable`, because JSC does not pause at a resolved breakpoint until the debugger activates breakpoints.
- `Debugger.setPauseOnDebuggerStatements` is sent after `Debugger.enable`, because JSC only stops at a `debugger` statement once a frontend arms that switch. CDP has no equivalent command.
- `Runtime.executionContextCreated` with one synthetic context after `Runtime.enable`. JSC has a single context and never announces it, and CDP clients wait for the announcement before they evaluate. `contextId` and `uniqueContextId` are dropped from forwarded requests, and evaluation results carry that context id.
- Offsets of column breakpoints are dropped, so the breakpoint resolves to the statement on the requested line instead of a later statement.
- A step out that returns to the end of the outermost statement reports the statement that made the call, matching other CDP engines.

## macOS

The macOS relay has no UNIX socket. `webinspectord` publishes only the `com.apple.webinspector` and `com.apple.webinspector.debugger` mach endpoints, and a third-party XPC client receives `Connection interrupted` from both services because the daemon checks for Apple's private Web Inspector entitlements. Producing a CDP endpoint for a macOS host therefore requires either a signed helper that holds those entitlements or an in-process debugger path that does not use the relay.

## Known fidelity differences

These come from the JSC target and its relay protocol rather than from the bridge:

- A step out that leaves a JavaScript callback which a native frame called resumes execution instead of pausing in the calling JavaScript frame, because the relay cannot step across native frames.
- Breakpoints are statement granular, so two breakpoints that resolve to the same statement collapse into one and the relay rejects the second as an existing location.
- Console API calls are not visible. JSC reports console output to the console client the host application installs, and the relay receives nothing, so CDP frontends show no `Runtime.consoleAPICalled` events. Breakpoints, stepping, and evaluation are unaffected. A host that reports its console messages to the Web Inspector console client makes them available to the relay.
- Block-scoped bindings are reported in a separate `block` scope. Frontends that merge block bindings into the frame's local scope show fewer names in the local scope.
- A breakpoint offset inside a multi-line expression resolves to the start of the statement that contains it.

## Tests

```sh
zig build test
```

`zig build test` covers the binary plist codec and the relay UUID format.

End-to-end checks against a simulator target live in `tests/apple-sdk/run-jsc-bridge-sim.sh` in the repository root. The script starts the demo and the bridge, runs the CDP debugger flow of `tests/inspector/e2e.cjs`, and skips the steps that describe behavior JSC cannot produce.
