# Inspector transport

This package supplies an optional loopback HTTP and WebSocket transport for an Inspector implementation. It serves Chrome DevTools discovery endpoints and forwards WebSocket text frames through the shared Inspector transport interface.

It is useful for tests, examples, and hosts that want a ready-made local CDP connection. It is not required by the engine or by CDP itself: embedders may provide any transport, including native IPC or an Electron bridge.

`Transport.init` returns an owned allocation. Passing `asTransport()` to an Inspector transfers that allocation's shutdown ownership immediately, including if attachment fails. Do not access or deinitialize the original pointer afterward.

Call `setProtocolJson` before starting to supply the supported protocol document. The slice must remain valid until shutdown; the default is `{}`. The engine integration selects its backend-specific document. The listener binds loopback only; hosts supply any device forwarding or desktop connection setup.

Run its tests with `zig build test --summary all` from this directory. The package owns HTTP discovery, WebSocket framing, callback shutdown, backpressure, session limits, allocation-failure, and concurrent-disconnect tests. These use loopback peers without a JavaScript engine. Tests of CDP commands against a real engine remain in the root repository; its full `zig build test` also runs this package suite. Engine integration and CDP limits are in the root [Inspector guide](../../docs/inspector.md).
