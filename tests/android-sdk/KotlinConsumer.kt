package io.jsbay.consumer

import io.jsbay.Engine
import io.jsbay.JsBayException
import io.jsbay.Status
import io.jsbay.SyncCompletion
import io.jsbay.Value
import io.jsbay.ValueKind
import java.io.File

private fun expectJsError(
    name: String,
    message: String,
    action: () -> Unit,
) {
    try {
        action()
        error(message)
    } catch (error: JsBayException) {
        check(error.status == Status.EXCEPTION && error.value != null) { "$message: ${error.status}" }
        error.value.use { thrown ->
            thrown.get("name").use { actual -> check(actual.string() == name) { "$message: ${actual.string()}" } }
        }
    }
}

private fun runKotlinObjectOperations(engine: Engine) {
    engine.evaluate("(function P(x){ this.x = x })", "kotlin-construct.js").use { point ->
        engine.number(42.0).use { answer ->
            point.construct(listOf(answer)).use { built ->
                built.get("x").use { check(it.number() == 42.0) { "Kotlin construct passes arguments" } }
                check(built.instanceOf(point)) { "Kotlin constructed value is instanceOf its constructor" }
            }
        }
    }
    engine.evaluate("(function Q(){ this.n = arguments.length })", "kotlin-construct-n.js").use { counter ->
        counter.construct().use { built ->
            built.get("n").use { check(it.number() == 0.0) { "Kotlin construct defaults to no arguments" } }
        }
    }
    engine.evaluate("(function B(){ throw new Error('ctor boom') })", "kotlin-ctor-boom.js").use { boom ->
        expectJsError("Error", "Kotlin construct propagates constructor throw") { boom.construct() }
    }
    engine.evaluate("(() => 1)", "kotlin-arrow-construct.js").use { arrow ->
        expectJsError("TypeError", "Kotlin construct rejects non-constructor") { arrow.construct() }
    }

    engine.evaluate("({a: 1})", "kotlin-has.js").use { target ->
        check(target.has("a")) { "Kotlin has own property" }
        check(target.has("toString")) { "Kotlin has inherited property" }
        check(!target.has("zzz")) { "Kotlin has missing property is false" }
    }
    engine.number(42.0).use { number ->
        expectJsError("TypeError", "Kotlin has rejects non-object") { number.has("a") }
    }
    engine.evaluate("new Proxy({}, { has(t, k) { throw new Error('trap') } })", "kotlin-has-trap.js").use { trap ->
        expectJsError("Error", "Kotlin has propagates Proxy trap throw") { trap.has("a") }
    }

    engine
        .evaluate(
            "(() => { const o = {a: 1};" +
                " Object.defineProperty(o, 'fixed', {value: 1, configurable: false});" +
                " return o })()",
            "kotlin-delete.js",
        ).use { target ->
            check(target.delete("a")) { "Kotlin delete configurable property" }
            check(!target.has("a")) { "Kotlin deleted property is gone" }
            check(!target.delete("fixed")) { "Kotlin delete non-configurable reports false" }
            check(target.has("fixed")) { "Kotlin non-configurable property survives delete" }
            check(target.delete("missing")) { "Kotlin delete missing property is true" }
        }
    engine.undefined().use { undefined ->
        expectJsError("TypeError", "Kotlin delete rejects undefined") { undefined.delete("a") }
    }
    engine.string("abc").use { text ->
        check(text.delete("zz")) { "Kotlin delete converts primitive with ToObject" }
    }

    engine
        .evaluate(
            "(() => { const o = {b: 1, 2: 1, a: 1, 1: 1};" +
                " Object.defineProperty(o, 'hidden', {value: 1, enumerable: false});" +
                " o[Symbol('s')] = 1; return o })()",
            "kotlin-keys.js",
        ).use { target ->
            target.keys().use {
                check(it.json() == "[\"1\",\"2\",\"b\",\"a\"]") { "Kotlin keys order and filtering: ${it.json()}" }
            }
        }
    engine.evaluate("Object.create({inherited: 1})", "kotlin-keys-inherited.js").use { inherited ->
        inherited.keys().use { check(it.json() == "[]") { "Kotlin keys excludes inherited keys" } }
    }
    engine
        .evaluate(
            "new Proxy({}, { ownKeys() { return ['z', 'y'] }," +
                " getOwnPropertyDescriptor() { return {value: 1, enumerable: true, configurable: true} } })",
            "kotlin-keys-proxy.js",
        ).use { ordered ->
            ordered.keys().use {
                check(it.json() == "[\"z\",\"y\"]") { "Kotlin keys follows Proxy ownKeys order: ${it.json()}" }
            }
        }
    engine.evaluate("null", "kotlin-keys-null.js").use { nothing ->
        expectJsError("TypeError", "Kotlin keys rejects null") { nothing.keys() }
    }

    engine
        .evaluate("(class { static [Symbol.hasInstance](v) { return v === 7 } })", "kotlin-has-instance.js")
        .use { custom ->
            engine.number(7.0).use { check(it.instanceOf(custom)) { "Kotlin instanceOf honors Symbol.hasInstance" } }
            engine
                .number(
                    8.0,
                ).use { check(!it.instanceOf(custom)) { "Kotlin instanceOf Symbol.hasInstance can decline" } }
        }
    engine.evaluate("[]", "kotlin-instance-array.js").use { array ->
        engine.evaluate("Array", "kotlin-instance-array-class.js").use {
            check(array.instanceOf(it)) { "Kotlin instanceOf matches prototype chain" }
        }
        engine.evaluate("Function", "kotlin-instance-function-class.js").use {
            check(!array.instanceOf(it)) { "Kotlin instanceOf rejects unrelated constructor" }
        }
        engine.evaluate("({})", "kotlin-instance-plain.js").use { plain ->
            expectJsError("TypeError", "Kotlin instanceOf rejects non-callable constructor") { array.instanceOf(plain) }
        }
    }
}

/** Kotlin-only public SDK conformance consumer. */
fun runKotlinConsumer() {
    fun rejected(
        status: Status,
        message: String,
        action: () -> Unit,
    ) {
        try {
            action()
            error(message)
        } catch (error: JsBayException) {
            check(
                error.status == status,
            ) { "$message: ${error.status}" }
        }
    }
    val mainInstanceId = 7102
    Engine(mainInstanceId).use { engine ->
        rejected(Status.INVALID_ARGUMENT, "Kotlin duplicate Engine id status") { Engine(mainInstanceId) }
        engine
            .evaluate(
                "40+2",
                "kotlin-duplicate-id.js",
            ).use { check(it.number() == 42.0) { "Kotlin duplicate id preserves original Engine" } }
        engine.evaluate("({answer: 42})", "kotlin-object.js").use { obj ->
            obj.get("answer").use { check(it.number() == 42.0) { "Kotlin live object" } }
        }
        engine.evaluate("(function(x){return x+1})", "kotlin-function.js").use { fn ->
            engine.number(41.0).use { n ->
                fn.call(args = listOf(n)).use {
                    check(
                        it.number() == 42.0,
                    ) { "Kotlin live function" }
                }
            }
        }
        var borrowed: Value? = null
        var escaped: Value? = null
        engine
            .bind("kotlinEcho") { _, args ->
                borrowed = args[0]
                args[0].retain().also { escaped = it }
            }.use {
                engine.evaluate("kotlinEcho({answer:42})", "kotlin-callback.js").use {
                    it.get("answer").use { answer ->
                        check(
                            answer.number() == 42.0,
                        ) { "Kotlin callback object" }
                    }
                }
            }
        rejected(Status.STALE_VALUE, "Kotlin borrowed callback Value expires") { borrowed!!.number() }
        rejected(Status.STALE_VALUE, "Kotlin borrowed callback close expires") { borrowed!!.close() }
        escaped!!.use { it.get("answer").use { answer -> check(answer.number() == 42.0) { "Kotlin retain escape" } } }
        engine.bind("kotlinThrow", { _, _ -> throw JsBayException(Status.EXCEPTION, engine.number(7.0)) }).use {
            try {
                engine.evaluate("kotlinThrow()", "kotlin-throw.js")
                error("Kotlin raw throw")
            } catch (
                error: JsBayException,
            ) {
                error.value!!.use {
                    check(
                        it.number() == 7.0,
                    ) { "Kotlin raw throw value" }
                }
            }
        }
        engine.bind("kotlinOrdinaryThrow") { _, _ -> throw RuntimeException("kotlin-bridge-msg-79102") }.use {
            try {
                engine.evaluate("kotlinOrdinaryThrow()", "kotlin-ordinary-throw.js")
                error("Kotlin ordinary throw")
            } catch (
                error: JsBayException,
            ) {
                error.value!!.use {
                    check(
                        it.string().contains("kotlin-bridge-msg-79102"),
                    ) { "Kotlin ordinary Throwable message" }
                }
            }
        }
        engine.bind("kotlinUnicodeThrow") { _, _ -> throw RuntimeException("kotlin-nul\u0000emoji😀") }.use {
            try {
                engine.evaluate("kotlinUnicodeThrow()", "kotlin-unicode-throw.js")
                error("Kotlin unicode throw")
            } catch (
                error: JsBayException,
            ) {
                error.value!!.use {
                    check(
                        it.string().contains("kotlin-nul\u0000emoji😀"),
                    ) { "Kotlin ordinary Throwable preserves NUL and emoji" }
                }
            }
        }
        engine
            .bind("kotlinHostileThrow") { _, _ ->
                throw object : RuntimeException("x") {
                    override fun toString(): String = error("hostile")
                }
            }.use {
                try {
                    engine.evaluate("kotlinHostileThrow()", "kotlin-hostile-throw.js")
                    error("Kotlin hostile throw")
                } catch (
                    error: JsBayException,
                ) {
                    error.value!!.use {
                        check(
                            it.string().contains("Java callback threw"),
                        ) { "Kotlin hostile Throwable falls back" }
                    }
                }
            }
        check(engine.startInspector() != null) { "Kotlin inspector starts" }
        engine.stopInspector()
        engine
            .bindSync("kotlinSync", 1000) { call ->
                Thread {
                    check(call.completion.tryResolveString("41") == Status.OK)
                }.start()
            }.use {
                engine.evaluate("Number(kotlinSync())+1", "kotlin-sync.js").use {
                    check(
                        it.number() == 42.0,
                    ) { "Kotlin sync resolves" }
                }
            }
        engine.number(1.0).close()
        var late: SyncCompletion? = null
        engine.bindSync("kotlinTimeout", 20) { call -> late = call.completion }.use {
            try {
                engine.evaluate("kotlinTimeout()", "kotlin-timeout.js")
                error("Kotlin sync timeout")
            } catch (
                error: JsBayException,
            ) {
                error.value!!.close()
            }
        }
        check(
            late!!.tryResolveString("1") == Status.STALE_VALUE,
        ) { "Kotlin late sync completion stale" }

        fun thrown(
            expected: Double,
            message: String,
            action: () -> Unit,
        ) {
            try {
                action()
                error(message)
            } catch (error: JsBayException) {
                error.value!!.use {
                    check(
                        it.number() == expected,
                    ) { message }
                }
            }
        }
        engine.evaluate("({set x(v){throw 7}})", "kotlin-setter.js").use { setter ->
            engine.number(1.0).use { one ->
                thrown(7.0, "Kotlin setter preserves throw value") { setter.set("x", one) }
            }
        }
        engine.evaluate("({toString(){throw 9}})", "kotlin-string-throw.js").use {
            thrown(9.0, "Kotlin toString preserves throw value") { it.string() }
        }
        engine
            .evaluate(
                "({toJSON(){throw 11}})",
                "kotlin-json-throw.js",
            ).use { thrown(11.0, "Kotlin toJSON preserves throw value") { it.json() } }
        try {
            engine.evaluate("throw 'kotlin-display\\u0000😀'", "kotlin-describe-and-close.js")
            error("Kotlin consuming description source")
        } catch (
            error: JsBayException,
        ) {
            check(error.describeAndClose() == "kotlin-display\u0000😀") { "Kotlin consuming description text" }
            rejected(Status.STALE_VALUE, "Kotlin consuming description closes original") { error.value!!.string() }
        }
        try {
            engine.evaluate("throw {toString(){throw 9}}", "kotlin-describe-and-close-secondary.js")
            error("Kotlin secondary consuming description source")
        } catch (
            error: JsBayException,
        ) {
            check(
                error.describeAndClose() == "JavaScript exception",
            ) { "Kotlin secondary consuming description fallback" }
            rejected(
                Status.STALE_VALUE,
                "Kotlin secondary consuming description closes original",
            ) { error.value!!.string() }
        }
        engine.objectValue().use { target ->
            engine.undefined().use { undefined ->
                try {
                    target.number()
                    error("Kotlin nonnumber must reject")
                } catch (error: JsBayException) {
                    check(
                        error.status == Status.INVALID_ARGUMENT,
                    ) { "Kotlin number status" }
                }
                try {
                    target.bool()
                    error("Kotlin nonbool must reject")
                } catch (error: JsBayException) {
                    check(
                        error.status == Status.INVALID_ARGUMENT,
                    ) { "Kotlin bool status" }
                }
                try {
                    undefined.json()
                    error("Kotlin undefined JSON must reject")
                } catch (error: JsBayException) {
                    check(
                        error.status == Status.INVALID_ARGUMENT,
                    ) { "Kotlin JSON undefined status" }
                }
            }
        }
        engine.bind("kotlinReenter") { _, _ -> engine.evaluate("40+2", "kotlin-reenter-inner.js") }.use {
            engine.evaluate("kotlinReenter()", "kotlin-reenter.js").use {
                check(
                    it.number() == 42.0,
                ) { "Kotlin recursive callback" }
            }
        }
        lateinit var binding: Value
        binding =
            engine.bind("kotlinClose") { _, _ ->
                binding.close()
                engine.undefined()
            }
        engine.evaluate("kotlinClose()", "kotlin-close-callback.js").use {
            check(
                it.kind().name == "UNDEFINED",
            ) { "Kotlin close in callback" }
        }
        engine.evaluate("Symbol('kind')", "kotlin-symbol-kind.js").use {
            check(it.kind() == ValueKind.SYMBOL) { "Kotlin symbol kind" }
        }
        engine.evaluate("1n", "kotlin-bigint-kind.js").use {
            check(it.kind() == ValueKind.BIGINT) { "Kotlin bigint kind" }
        }
        Engine(7105).use { other ->
            other.number(1.0).use { foreign ->
                engine.objectValue().use { target ->
                    rejected(Status.STALE_VALUE, "Kotlin cross-engine reject") { target.set("foreign", foreign) }
                    engine.evaluate("(function(){})", "kotlin-cross-construct.js").use { constructor ->
                        rejected(Status.STALE_VALUE, "Kotlin construct cross-engine argument reject") {
                            constructor.construct(listOf(foreign))
                        }
                    }
                    rejected(Status.STALE_VALUE, "Kotlin instanceOf cross-engine constructor reject") {
                        target.instanceOf(foreign)
                    }
                }
            }
        }
        runKotlinObjectOperations(engine)
        val dead = Engine(7106)
        val stale = dead.number(9.0)
        dead.close()
        rejected(Status.STALE_VALUE, "Kotlin destroyed Value expires") { stale.number() }
        val callEngine = Engine(7108)
        val deadFunction = callEngine.evaluate("(()=>42)", "kotlin-dead-call.js")
        val deadReceiver = callEngine.objectValue()
        callEngine.close()
        rejected(Status.STALE_VALUE, "Kotlin closed Engine default receiver call") { deadFunction.call() }
        rejected(Status.STALE_VALUE, "Kotlin closed Engine explicit receiver call") { deadFunction.call(deadReceiver) }
        deadFunction.close()
        deadReceiver.close()
        val doubleClose = engine.number(1.0)
        doubleClose.close()
        doubleClose.close()
        val closedEngine = Engine(7107)
        closedEngine.close()
        rejected(Status.INSTANCE_NOT_FOUND, "Kotlin closed Engine status") { closedEngine.number(1.0) }
        engine
            .bind("kotlinCloseBorrowed") { _, args ->
                rejected(Status.INVALID_ARGUMENT, "Kotlin borrowed close status") { args[0].close() }
                engine.undefined()
            }.use { engine.evaluate("kotlinCloseBorrowed(1)", "kotlin-borrowed-close.js").close() }
        engine
            .bind("kotlinBorrowedDescription") { thisValue, _ ->
                rejected(
                    Status.INVALID_ARGUMENT,
                    "Kotlin borrowed exception text",
                ) { JsBayException(Status.EXCEPTION, thisValue).describeAndClose() }
                engine.undefined()
            }.use { engine.evaluate("kotlinBorrowedDescription()", "kotlin-borrowed-description.js").close() }
        var wrongThread: Throwable? = null
        val worker =
            Thread {
                try {
                    engine.number(1.0)
                } catch (
                    error: Throwable,
                ) {
                    wrongThread = error
                }
            }
        worker.start()
        worker.join()
        check(
            wrongThread is JsBayException && (wrongThread as JsBayException).status == Status.WRONG_THREAD,
        ) { "Kotlin wrong thread status" }
        val malformed = "\uD800"
        engine.objectValue().use { target ->
            rejected(Status.INVALID_ARGUMENT, "Kotlin malformed source") { engine.evaluate(malformed) }
            rejected(Status.INVALID_ARGUMENT, "Kotlin malformed filename") { engine.evaluate("1", malformed) }
            rejected(
                Status.INVALID_ARGUMENT,
                "Kotlin malformed cache directory",
            ) { engine.evaluate("1", "x", malformed, "v") }
            rejected(
                Status.INVALID_ARGUMENT,
                "Kotlin malformed cache version",
            ) { engine.evaluate("1", "x", "d", malformed) }
            rejected(
                Status.INVALID_ARGUMENT,
                "Kotlin malformed bind",
            ) { engine.bind(malformed) { _, _ -> engine.undefined() } }
            rejected(Status.INVALID_ARGUMENT, "Kotlin malformed string") { engine.string(malformed) }
            rejected(Status.INVALID_ARGUMENT, "Kotlin malformed error") { engine.error(malformed) }
            rejected(Status.INVALID_ARGUMENT, "Kotlin malformed json") { engine.json(malformed) }
            rejected(Status.INVALID_ARGUMENT, "Kotlin malformed get key") { target.get(malformed) }
            rejected(Status.INVALID_ARGUMENT, "Kotlin malformed set key") { target.set(malformed, target) }
        }
        engine
            .evaluate(
                "globalThis.kotlinMicro=0;queueMicrotask(()=>kotlinMicro=1);setTimeout(()=>globalThis.kotlinTimer=9,10)",
                "kotlin-timer.js",
            ).use {
                check(engine.stopLoop()) { "Kotlin stop loop is thread-safe" }
            }
        val cache =
            File.createTempFile("jsbay-kotlin-cache", ".cache").also {
                check(it.delete() && it.mkdir()) { "Kotlin cache directory" }
            }
        engine
            .evaluate(
                "globalThis.kotlinCache=(globalThis.kotlinCache||0)+1;kotlinCache",
                "kotlin-cache.js",
                cache.absolutePath,
                "v1",
            ).use { cold ->
                engine
                    .evaluate(
                        "globalThis.kotlinCache=(globalThis.kotlinCache||0)+1;kotlinCache",
                        "kotlin-cache.js",
                        cache.absolutePath,
                        "v1",
                    ).use { warm ->
                        check(
                            cold.number() == 1.0 && warm.number() == 2.0 && engine.lastCacheHit,
                        ) { "Kotlin cache single execution" }
                    }
            }
        val input = byteArrayOf(0, 1, -1, 42)
        engine.arrayBuffer(byteArrayOf()).use { empty ->
            engine.arrayBuffer(input).use { buffer ->
                input[1] = 99
                check(
                    empty.bytes().isEmpty() && buffer.bytes().contentEquals(byteArrayOf(0, 1, -1, 42)),
                ) { "Kotlin buffer copy-in" }
                val copied = buffer.bytes()
                copied[2] = 0
                check(buffer.bytes()[2] == (-1).toByte()) { "Kotlin copy-out isolation" }
            }
        }
        engine.evaluate("new Uint8Array([8,9,0,255,7]).subarray(2,4)", "kotlin-view.js").use { view ->
            engine
                .evaluate(
                    "new DataView(new Uint8Array([8,9,0,255,7]).buffer,2,2)",
                    "kotlin-dataview.js",
                ).use { dataView ->
                    check(
                        view.bytes().contentEquals(
                            byteArrayOf(0, -1),
                        ) &&
                            dataView.bytes().contentEquals(byteArrayOf(0, -1)),
                    ) { "Kotlin buffer view offset" }
                }
        }
        engine.evaluate("'\\uD800'", "kotlin-surrogate.js").use { surrogate ->
            engine.evaluate("'A\\0😀'", "kotlin-utf8.js").use { text ->
                check(
                    surrogate.string() == "\uFFFD" && text.string() == "A\u0000😀",
                ) { "Kotlin UTF-8 replacement, emoji, and NUL" }
            }
        }
    }
    var closeLate: SyncCompletion? = null
    Engine(7103).use { engine ->
        engine.bindSync("closeWakeTimeout", 20) { call -> closeLate = call.completion }.use {
            try {
                engine.evaluate("closeWakeTimeout()", "close-wake-timeout.js")
                error("close wake timeout")
            } catch (
                error: JsBayException,
            ) {
                error.value!!.close()
            }
        }
    }
    check(closeLate!!.tryResolveString("1") == Status.STALE_VALUE) { "Kotlin close rejects late completion" }
    val closed = Engine(mainInstanceId)
    closed.close()
    Engine(mainInstanceId).use { replacement ->
        replacement.evaluate("40+2", "kotlin-reused-id.js").use { result ->
            check(!closed.requestInterrupt()) { "Kotlin closed Engine requestInterrupt rejects reused id" }
            check(result.number() == 42.0) { "Kotlin replacement Engine remains runnable" }
        }
    }
}
