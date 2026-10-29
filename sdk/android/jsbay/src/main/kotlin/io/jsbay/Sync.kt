package io.jsbay

/** Starts a native synchronous operation. It must return promptly. */
fun interface SyncStarter {
    fun start(call: SyncCall)
}

/** Values available only while [SyncStarter.start] runs on the engine owner thread. */
class SyncCall internal constructor(
    val thisValue: Value,
    val args: List<Value>,
    val completion: SyncCompletion,
)

/**
 * Thread-safe, single-use completion token. Copies bytes to native code and deliberately exposes no
 * JavaScript [Value]. Prefer resolving from an NDK/native worker via `jsbay_sync_complete` to avoid
 * JNI on the hot path; these Kotlin helpers are a thin JNI bridge for convenience.
 */
class SyncCompletion internal constructor(
    private val requestId: Long,
) {
    private val lock = Any()
    private var terminal = false

    fun resolveString(value: String) = requireCompleted(tryResolveString(value))

    fun resolveBytes(bytes: ByteArray) = requireCompleted(tryResolveBytes(bytes))

    fun reject(message: String) = requireCompleted(tryReject(message))

    fun tryResolveString(value: String): Status {
        val bytes = strictUtf8(value) ?: return Status.INVALID_ARGUMENT
        return complete(Status.OK, SyncPayloadKind.UTF8_STRING, bytes)
    }

    fun tryResolveBytes(bytes: ByteArray): Status = complete(Status.OK, SyncPayloadKind.BYTES, bytes)

    fun tryReject(message: String): Status {
        val bytes = strictUtf8(message) ?: return Status.INVALID_ARGUMENT
        return complete(Status.EXCEPTION, SyncPayloadKind.UTF8_STRING, bytes)
    }

    private fun complete(
        outcome: Status,
        kind: SyncPayloadKind,
        bytes: ByteArray,
    ): Status {
        synchronized(lock) {
            if (terminal) return Status.STALE_VALUE
            val status = Status.of(Native.syncComplete(requestId, outcome.code, kind.code, bytes))
            if (status == Status.OK || status == Status.STALE_VALUE) terminal = true
            return status
        }
    }

    private fun requireCompleted(status: Status) {
        if (status != Status.OK) throw JsBayException(status)
    }
}

enum class SyncPayloadKind(
    val code: Int,
) {
    UTF8_STRING(0),
    BYTES(1),
    JSON(2),
}

private fun strictUtf8(value: String): ByteArray? =
    if (value.hasValidSurrogatePairs()) value.toByteArray(Charsets.UTF_8) else null
