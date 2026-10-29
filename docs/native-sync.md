# Synchronous native calls

`jsbay_sync.h` is an optional extension for a native operation that starts on the JavaScript owner thread and must return a value synchronously after an external completion. Register it with `jsbay_engine_bind_sync`.

The start callback runs on the owner thread. Its `this` value and arguments are borrowed and valid only during that callback. Copy ordinary input before starting external work. The external completion may run on another thread and may call only `jsbay_sync_complete`; it passes a request ID, an outcome, a payload kind, and copied bytes. It must not keep a JS value, call any other engine API, or require the blocked owner queue to execute first.

The library copies completion bytes once into the request. Value creation remains on the owner thread. For `BYTES` + `OK`, QuickJS backends adopt that buffer into an ArrayBuffer (no second copy). `UTF8_STRING` builds a JS string without `JSON.parse`. `JSON` is an explicit opt-in that still parses on the owner.

| Kind | `JSBAY_OK` | `JSBAY_EXCEPTION` |
| --- | --- | --- |
| `JSBAY_SYNC_PAYLOAD_UTF8_STRING` (primary) | string (no parse) | UTF-8 message via `jsbay_value_new_error` |
| `JSBAY_SYNC_PAYLOAD_BYTES` (primary) | ArrayBuffer (opaque octets; may adopt) | Octets treated as UTF-8 error message via `new_error` |
| `JSBAY_SYNC_PAYLOAD_JSON` (explicit opt-in) | Parse JSON → return value | Parse JSON → throw value (invalid JSON → exception) |

There is no JSON-only completion entry point. Completers must pass a kind. Prefer calling `jsbay_sync_complete` from native/NDK workers; do not route hot-path payloads through JNI JSON helpers.

A registered timeout must be nonzero and finite. The execution deadline can shorten an active request. Interrupt, timeout, destruction, duplicate completion, and unknown completion end the request; a later completion returns `JSBAY_STALE_VALUE`. An invalid outcome, kind, or invalid UTF-8 (when required) returns `JSBAY_INVALID_ARGUMENT`. `BYTES` + `OK` does not require UTF-8. An out-of-memory completion can be retried while the request remains active.

Waiting does not pump JavaScript or a nested host event loop, and cancelling a wait does not cancel the host operation. The host owns cancellation of that operation and must safely ignore its late completion. This extension is unsuitable for APIs whose completion is scheduled on the same blocked owner queue.
