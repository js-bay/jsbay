# Native asynchronous calls

Include `jsbay_async.h` when a native operation should return a Promise without blocking JavaScript. The engine owner creates the Promise and hands the host a request ID. A completion thread submits copied bytes with that ID; the engine queues settlement on its owner thread. No JavaScript request table or Promise factory needs to be injected.

Use `jsbay_promise_settle` when the result is already an owned JavaScript value on the engine thread. It borrows that value, so the caller must still release its handle. Use `jsbay_async_complete` from a host completion thread; it accepts data rather than value handles. Callback arguments and `this` remain borrowed and must not cross threads.

## Result representation

Pass `JSBAY_OK` to resolve or `JSBAY_EXCEPTION` to reject:

| Payload kind | Resolve | Reject |
| --- | --- | --- |
| `JSBAY_ASYNC_PAYLOAD_UTF8_STRING` | UTF-8 string | Error with the UTF-8 message |
| `JSBAY_ASYNC_PAYLOAD_BYTES` | Copied ArrayBuffer; bytes need not be UTF-8 | Error message; bytes must be UTF-8 |
| `JSBAY_ASYNC_PAYLOAD_JSON` | Parsed JSON value | Parsed JSON value, including primitive reasons |
| `JSBAY_ASYNC_PAYLOAD_UNDEFINED` | Undefined; payload must be empty | Invalid argument |

Malformed JSON rejects with its parse error on the owner thread. JSON is an explicit representation choice, not a requirement for ordinary host values. Owner-thread settlement preserves the original value and normal Promise adoption behavior.

## C example

Save this program as `native-async-example.c`. It queues a completed host result before starting the owner loop. A real host operation can invoke `complete_read` on its completion thread instead; only the request ID crosses that boundary.

```c
#include "jsbay_async.h"
#include <stdio.h>
#include <string.h>

#define TEXT(value) ((jsbay_utf8_t){(const uint8_t *)(value), sizeof(value) - 1})
static bool received = false;

static jsbay_status_t finished(int id, void *data, jsbay_value_t receiver,
                               size_t argc, const jsbay_value_t *args,
                               jsbay_value_t *out, jsbay_value_t *exception) {
    (void)data;
    (void)receiver;
    jsbay_engine_stop_loop(id);
    if (argc != 1) return JSBAY_INVALID_ARGUMENT;
    jsbay_bytes_t bytes = {0};
    jsbay_status_t status = jsbay_value_to_utf8(args[0], &bytes, exception);
    if (status != JSBAY_OK) return status;
    received = bytes.len == 5 && memcmp(bytes.data, "ready", 5) == 0;
    jsbay_free_bytes(bytes);
    return jsbay_value_undefined(id, out);
}

static jsbay_status_t complete_read(uint64_t request) {
    return jsbay_async_complete(request, JSBAY_OK,
                                JSBAY_ASYNC_PAYLOAD_UTF8_STRING, TEXT("ready"));
}

int main(void) {
    const int id = 1;
    uint64_t request = 0;
    jsbay_value_t promise = 0, global = 0, function = 0, value = 0, exception = 0;
    int result = 1;
    if (!jsbay_engine_create(id, NULL, NULL)) return result;
    if (jsbay_engine_bind(id, TEXT("finished"), finished, NULL, NULL,
                          &function, &exception) != JSBAY_OK) goto done;
    if (jsbay_promise_create(id, &request, &promise, &exception) != JSBAY_OK) goto done;
    if (jsbay_engine_global(id, &global) != JSBAY_OK) goto done;
    if (jsbay_value_set(global, TEXT("nativeResult"), promise, &exception) != JSBAY_OK) goto done;
    if (jsbay_engine_evaluate(id, TEXT("nativeResult.then(finished); void 0"),
                              TEXT("app.js"), NULL, &value, &exception) != JSBAY_OK) goto done;
    if (complete_read(request) != JSBAY_OK) goto done;
    if (jsbay_engine_run_loop(id) != JSBAY_OK || !received) goto done;
    puts("ready");
    result = 0;
done:
    if (value) jsbay_value_release(value);
    if (exception) jsbay_value_release(exception);
    if (function) jsbay_value_release(function);
    if (global) jsbay_value_release(global);
    if (promise) jsbay_value_release(promise);
    jsbay_engine_destroy(id);
    return result;
}
```

Build a QuickJS-NG archive from the repository root with `zig build -Dlibrary-only=true -Dbackend=quickjs_ng -Doptimize=ReleaseFast`. On Linux, compile the example with:

```sh
cc -std=c11 -Iinclude native-async-example.c zig-out/lib/libjsbay.a -lm -pthread -o native-async-example
./native-async-example
```

On macOS, add `-framework Foundation -framework JavaScriptCore` to the compiler command. Expected output is `ready`.

## Completion and shutdown

Successful completion means one task was accepted, not that its Promise has already settled. Keep the owner loop running, or attach a platform loop through `jsbay_engine_attach_loop`. The Node.js SDK attaches its loop automatically.

The first accepted completion, owner-thread settlement, or cancellation wins. Later attempts return `JSBAY_STALE_VALUE`. A failed admission can be retried while the request and engine generation remain live. A competing call during admission also returns retryable `JSBAY_OUT_OF_MEMORY`; it does not falsely report that the request has already ended. Creation reserves a pending-call slot; completion reserves a native-task slot and payload bytes before copying. Limits and allocation failures can return `JSBAY_OUT_OF_MEMORY`.

If the owner cannot allocate a result or cancellation reason after admission, it rejects with an Error retained when the request was created. This fallback does not require allocating a new reason while handling the failure. Terminal cancellation and destruction can still discard delivery as described below.

`jsbay_async_cancel` queues rejection with an Error. It does not interrupt the host's I/O or cancel an external host Promise. The host must stop that work or safely ignore its late completion. Engine destruction and terminal generation cancellation can discard accepted tasks without running JavaScript. A cancelled generation cannot be resumed, and its host must destroy the engine to finish releasing requests that have no queued delivery.

QuickJS, QuickJS-NG, and JSC primary instances use native Promise support. Non-primary instances in a packed library return `JSBAY_UNSUPPORTED` for Promise creation. See the [API contract](api-contract.md#native-promise-extension) for ownership and status rules, [testing](testing.md#native-promise-and-nodejs-consumers) for regression commands, and the [Node.js SDK](../sdk/node/README.md) for language-level asynchronous bindings.
