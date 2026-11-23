package io.jsbay

/** Destruction protocol v2 progress; PENDING never means that resources were released. */
enum class CloseStatus(
    val native: Int,
) {
    LIVE(0),
    PENDING(1),
    COMPLETE(2),
    INVALID_ARGUMENT(3),
    WRONG_THREAD(4),
    STALE(5),
    ALREADY_CLOSING(6),
    ;

    companion object {
        internal fun of(raw: Int): CloseStatus = entries.first { it.native == raw }
    }
}
