package io.jsbay.interop

import io.jsbay.Engine

private const val WARMUP = 100
private const val ITERATIONS = 1000
private const val PAYLOAD_BYTES = 4096

private fun elapsed(
    count: Int = ITERATIONS,
    operation: () -> Unit,
): Long {
    repeat(WARMUP) { operation() }
    val started = System.nanoTime()
    repeat(count) { operation() }
    return System.nanoTime() - started
}

private fun number(
    engine: Engine,
    source: String,
) {
    engine.evaluate(source, "interop.js").use { value ->
        check(value.number() == 42.0) { "unexpected benchmark result" }
    }
}

private fun lifecycle(): Long {
    repeat(WARMUP) { index -> Engine(2_100_000 + index).use { engine -> number(engine, "42") } }
    val started = System.nanoTime()
    repeat(100) { index -> Engine(2_100_100 + index).use { engine -> number(engine, "42") } }
    return System.nanoTime() - started
}

fun main() {
    Engine(2_000_001).use { engine ->
        engine.bind("benchCallback") { _, _ -> engine.number(42.0) }.use { callback ->
            val eval = elapsed { number(engine, "var n=0; for(var i=0;i<64;i++)n+=i; 42") }
            val hostCallback = elapsed { number(engine, "benchCallback()") }
            val textJson =
                elapsed {
                    engine.evaluate("({text:'public interop',count:42})", "text-json.js").use { value ->
                        check(value.json() == "{\"text\":\"public interop\",\"count\":42}") { "unexpected JSON" }
                    }
                }
            val input = ByteArray(PAYLOAD_BYTES) { 7 }
            val bufferCopy =
                elapsed {
                    engine.arrayBuffer(input).use { value ->
                        check(value.bytes().contentEquals(input)) { "buffer mismatch" }
                    }
                }
            val life = lifecycle()
            check(callback.kind().name == "FUNCTION") { "callback closed unexpectedly" }
            println("$eval $hostCallback $textJson $bufferCopy $life")
        }
    }
}
