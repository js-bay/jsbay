package io.jsbay

/** Java- and Kotlin-friendly synchronous native binding. */
fun interface Callback {
    fun invoke(
        thisValue: Value,
        args: List<Value>,
    ): Value
}
