# Inspector

This package owns CDP sessions, command handling, events, and retained JavaScript objects. It does not open sockets or depend on the HTTP/WebSocket transport package. A host supplies engine operations and decides how messages reach the debugger.

## Engine integration

`Inspector(Host)` creates an implementation for a compile-time host type. `Host` supplies the backend value API, engine lifecycle and thread operations, task dispatch, debugger hooks, console hooks, clocks, synchronization, and build capabilities. The engine repository's `src/inspector/inspector_host.zig` implements that contract for its three backends. These interfaces must stay compatible when updating the package and engine together; this is not a universal adapter for arbitrary JavaScript engines.

The package exports its shared `Transport`, `Event`, `SessionId`, and `DiscoveryTarget` types. A transport's `start` callback receives the event handler and context; feed it `session_opened`, `message`, and `session_closed` events. Responses and notifications go to the transport's `send_text` and `broadcast_text` callbacks.

```zig
const Core = inspector.Inspector(Host);
const handle = try Core.start(instance_id, .{
    .transport = &host_transport,
    .title = "simulator",
});
defer Core.stop(handle);
```

`Core.start` takes shutdown ownership of the transport immediately, including when attachment fails. Its `deinit` is called exactly once for that attachment. The transport value must remain at a stable address until shutdown; `deinit` must stop and quiesce its incoming event callbacks before returning. An implementation may release its own allocation there, so callers must not access it afterward.

Incoming `Event.payload` is borrowed for the handler call. Outgoing text is borrowed for the send callback: consume it or make an owned copy before returning. Report session closure so Inspector can cancel pending work and release session state. Transport callbacks may run on different threads; engine evaluation is posted to the engine's owner thread.

The root engine exposes `startWithTransport` for this path. Its existing port-based `start` composes this package with `inspector_transport`. Engine-specific build options and CDP compatibility live in the root [Inspector guide](../../docs/inspector.md).

## Tests and protocol files

Run `zig build test --summary all` in this directory for protocol, transport-interface, console-group, profiler-lifecycle, and state-bookkeeping unit tests. Tests that require the engine host run from the root repository: real evaluation, retained values, task dispatch, session isolation, failure rollback, and shutdown. The root test suite explicitly registers the package's host-dependent contracts and also runs both packages' independent suites. The optional network package owns its loopback and connection-lifecycle tests.

The support manifest and generated protocol variants live under `src/`. From the repository root, regenerate them with `node scripts/generate-cdp-protocol.mjs --source-root <fixed-protocol-directory>`; add `--check` to verify existing output. `--fetch` retrieves the exact commit recorded in the manifest and verifies its source hashes.

Package unit fixtures do not execute JavaScript or wait on conditions; unexpected value retention, value release, or condition waits fail immediately. Real value ownership and concurrent task shutdown are checked with the engine host. Generic module contracts expose `TestCases` only in test builds and are invoked by ordinary test declarations, so test discovery does not depend on generic nested tests.
