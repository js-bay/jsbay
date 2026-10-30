package io.jsbay

/** Process-wide admission preference for native timer/task budgets. Default [FOREGROUND]. */
enum class AdmissionClass(
    val native: Int,
) {
    FOREGROUND(0),
    BACKGROUND(1),
    ;

    companion object {
        fun fromNative(value: Int): AdmissionClass? = entries.firstOrNull { it.native == value }
    }
}
