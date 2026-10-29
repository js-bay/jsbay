package io.jsbay

enum class Status(
    val code: Int,
) {
    OK(0),
    EXCEPTION(1),
    INVALID_ARGUMENT(2),
    WRONG_THREAD(3),
    INSTANCE_NOT_FOUND(4),
    STALE_VALUE(5),
    OUT_OF_MEMORY(6),
    UNSUPPORTED(7),
    LOOP_FAILED(8),
    ;

    companion object {
        fun of(code: Int) = entries.firstOrNull { it.code == code } ?: INVALID_ARGUMENT
    }
}

enum class ValueKind { UNDEFINED, NULL, BOOL, NUMBER, STRING, OBJECT, ARRAY, FUNCTION, SYMBOL, BIGINT }

class JsBayException
    @JvmOverloads
    constructor(
        val status: Status,
        val value: Value? = null,
    ) : RuntimeException("js-bay: $status") {
        val thrown: Value? get() = value

        /** Consumes a JavaScript throw; a second JavaScript throw closes both values and returns a fixed fallback. */
        fun describeAndClose(): String {
            val original = value ?: return message ?: "js-bay: $status"
            original.requireOwnedForConsume()
            try {
                val description = original.string()
                original.close()
                return description
            } catch (secondary: JsBayException) {
                if (secondary.value == null) throw secondary
                try {
                    secondary.value.close()
                } finally {
                    original.close()
                }
                return "JavaScript exception"
            }
        }
    }
