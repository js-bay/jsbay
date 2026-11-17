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

data class JsExceptionDetails(
    val message: String,
    val stackTraceString: String?,
    val fileName: String?,
    val lineNumber: Int?,
    val columnNumber: Int?,
)

class JsBayException
    @JvmOverloads
    constructor(
        val status: Status,
        val value: Value? = null,
    ) : RuntimeException("js-bay: $status") {
        val thrown: Value? get() = value

        fun details(): JsExceptionDetails {
            val original = value ?: return JsExceptionDetails(message ?: "js-bay: $status", null, null, null, null)
            original.kind()
            return JsExceptionDetails(
                message = readString(original, "message") ?: original.stringOrNull() ?: "JavaScript exception",
                stackTraceString = readString(original, "stack"),
                fileName = readString(original, "fileName") ?: readString(original, "sourceURL"),
                lineNumber = readInteger(original, "lineNumber") ?: readInteger(original, "line"),
                columnNumber = readInteger(original, "columnNumber") ?: readInteger(original, "column"),
            )
        }

        fun detailsAndClose(): JsExceptionDetails {
            val original = value ?: return details()
            original.requireOwnedForConsume()
            return try {
                details()
            } finally {
                original.close()
            }
        }

        fun describeDetailedAndClose(): String {
            val details = detailsAndClose()
            val stack = details.stackTraceString?.takeIf(String::isNotEmpty) ?: return details.message
            if (details.message.isEmpty()) return stack
            return if (stack.substringBefore('\n').contains(details.message)) {
                stack
            } else {
                "${details.message}\n$stack"
            }
        }

        private fun readString(
            original: Value,
            key: String,
        ): String? =
            try {
                original.get(key).use { field ->
                    when (field.kind()) {
                        ValueKind.UNDEFINED, ValueKind.NULL -> null
                        else -> field.string()
                    }
                }
            } catch (secondary: JsBayException) {
                if (secondary.status != Status.EXCEPTION) throw secondary
                secondary.value?.close()
                null
            }

        private fun readInteger(
            original: Value,
            key: String,
        ): Int? =
            try {
                original.get(key).use { field ->
                    when (field.kind()) {
                        ValueKind.NUMBER ->
                            field
                                .number()
                                .takeIf {
                                    it.isFinite() &&
                                        it >= 0.0 &&
                                        it <= Int.MAX_VALUE &&
                                        it % 1.0 == 0.0
                                }?.toInt()
                        else -> null
                    }
                }
            } catch (secondary: JsBayException) {
                if (secondary.status != Status.EXCEPTION) throw secondary
                secondary.value?.close()
                null
            }

        private fun Value.stringOrNull(): String? =
            try {
                string()
            } catch (secondary: JsBayException) {
                if (secondary.status != Status.EXCEPTION) throw secondary
                secondary.value?.close()
                null
            }

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
