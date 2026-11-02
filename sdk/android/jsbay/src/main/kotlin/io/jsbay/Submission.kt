package io.jsbay

enum class SubmissionStatus(
    val native: Int,
) {
    COMPLETED(0),
    EXCEPTION(1),
    CANCELLED(2),
    ;

    companion object {
        fun of(value: Int): SubmissionStatus = entries.firstOrNull { it.native == value } ?: CANCELLED
    }
}

enum class ShutdownPhase(
    val native: Int,
) {
    OPEN(0),
    CLOSING(1),
    SEALED(2),
    DRAINED(3),
    CANCELLED(4),
    ;

    companion object {
        fun of(value: Int): ShutdownPhase? = entries.firstOrNull { it.native == value }
    }
}

data class SubmissionResult(
    val status: SubmissionStatus,
    val error: String,
)

data class ShutdownStatus(
    val phase: ShutdownPhase,
    val remainingMilliseconds: Long,
)

fun interface SubmissionCallback {
    fun onComplete(
        status: Int,
        error: ByteArray?,
    )
}
