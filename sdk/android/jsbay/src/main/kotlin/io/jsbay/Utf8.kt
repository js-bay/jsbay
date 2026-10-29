package io.jsbay

/** Rejects lone UTF-16 surrogates before the JVM UTF-8 encoder can replace them. */
internal fun String.hasValidSurrogatePairs(): Boolean {
    var index = 0
    while (index < length) {
        val character = this[index]
        if (character.isHighSurrogate()) {
            if (index + 1 == length || !this[index + 1].isLowSurrogate()) return false
            index += 2
        } else {
            if (character.isLowSurrogate()) return false
            index++
        }
    }
    return true
}
