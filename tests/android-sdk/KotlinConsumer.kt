package io.jsbay.consumer

import io.jsbay.CloseStatus
import io.jsbay.DedicatedEngineThread
import io.jsbay.DedicatedEngineThreadState
import io.jsbay.DedicatedEngineThreadTimeoutException
import io.jsbay.Engine
import io.jsbay.JsBayException
import io.jsbay.ShutdownPhase
import io.jsbay.Status
import io.jsbay.SubmissionResult
import io.jsbay.SubmissionStatus
import io.jsbay.SyncCompletion
import io.jsbay.Value
import io.jsbay.ValueKind
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Drain the current thread's Looper for [milliseconds] of wall-clock time.
 *
 * Host tests compile against tests/android-sdk/android/os/Looper.java, which
 * exposes advanceBy. Official device scripts compile against the real
 * android.jar, which has no such method. This helper calls advanceBy when
 * present (same semantics as the stub) and otherwise pumps the platform
 * MessageQueue until a delayed sentinel runs, so LoopDriver callbacks fire.
 *
 * After the window, already-due work is flushed — including delay-0 callbacks
 * re-armed while a previous due turn ran — so a finite FIFO still completes
 * when one turn overruns the window (TCG). isIdle is true only when the queue
 * is empty or the head is still in the future, so later timers are not waited
 * out and the Looper is not quit. The post-window flush is capped
 * ([MAX_DUE_FLUSH_MESSAGES]) so a Host.schedule(0) livelock cannot spin this
 * helper without bound. Hitting the cap with work still queued is an error,
 * not a silent under-run.
 */
private const val MAX_DUE_FLUSH_MESSAGES = 256

private fun advanceCurrentLooper(milliseconds: Long) {
    require(milliseconds >= 0) { "milliseconds" }
    val looper = android.os.Looper.myLooper() ?: error("Kotlin consumer requires a prepared Looper")
    try {
        looper.javaClass.getMethod("advanceBy", Long::class.javaPrimitiveType).invoke(looper, milliseconds)
        return
    } catch (_: NoSuchMethodException) {
        // Real android.os.Looper.
    } catch (error: java.lang.reflect.InvocationTargetException) {
        throw (error.targetException ?: error)
    }
    // Real Looper has no advanceBy. Pump MessageQueue.next() for the requested window, then flush already-due work up to MAX_DUE_FLUSH_MESSAGES.
    val handler = android.os.Handler(looper)
    val uptimeMillis = Class.forName("android.os.SystemClock").getMethod("uptimeMillis")

    fun uptime() = uptimeMillis.invoke(null) as Long
    val deadlineUptime = uptime() + milliseconds
    val windowElapsed =
        java.util.concurrent.atomic
            .AtomicBoolean(milliseconds == 0L)
    if (milliseconds > 0) {
        handler.postDelayed({ windowElapsed.set(true) }, milliseconds)
    }
    val queueClass = Class.forName("android.os.MessageQueue")
    val messageClass = Class.forName("android.os.Message")
    val queue = looper.javaClass.getMethod("getQueue").invoke(looper)
    val isIdle = queueClass.getMethod("isIdle")
    val next = queueClass.getDeclaredMethod("next").apply { isAccessible = true }
    val getTarget = messageClass.getMethod("getTarget")
    val dispatchMessage = android.os.Handler::class.java.getMethod("dispatchMessage", messageClass)
    val recycle =
        try {
            messageClass.getDeclaredMethod("recycleUnchecked").apply { isAccessible = true }
        } catch (_: NoSuchMethodException) {
            messageClass.getMethod("recycle")
        }
    var dueFlushed = 0
    while (true) {
        if (windowElapsed.get()) {
            if (isIdle.invoke(queue) as Boolean) break
            check(dueFlushed < MAX_DUE_FLUSH_MESSAGES) {
                "advanceCurrentLooper due-flush cap ($MAX_DUE_FLUSH_MESSAGES) reached with work still queued"
            }
        }
        val msg = next.invoke(queue) ?: break
        val target = getTarget.invoke(msg)
        if (target != null) {
            try {
                dispatchMessage.invoke(target, msg)
            } catch (error: java.lang.reflect.InvocationTargetException) {
                throw (error.targetException ?: error)
            }
        }
        try {
            recycle.invoke(msg)
        } catch (_: Throwable) {
        }
        if (uptime() >= deadlineUptime) {
            windowElapsed.set(true)
        }
        if (windowElapsed.get()) {
            dueFlushed += 1
        }
    }
}

private fun expectJsError(
    name: String,
    message: String,
    action: () -> Unit,
) {
    try {
        action()
        error(message)
    } catch (error: JsBayException) {
        // Local binding: Kotlin will not smart-cast JsBayException.value (Value?) when the SDK typings come from an AAR / other module.
        val thrownValue = error.value
        check(error.status == Status.EXCEPTION && thrownValue != null) { "$message: ${error.status}" }
        thrownValue.use { thrown ->
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
            val details = error.details()
            check(details.message == "kotlin-display\u0000😀") { "Kotlin exception snapshot preserves text" }
            check(error.value!!.get("length").use { it.number() } > 0.0) { "Kotlin snapshot preserves original" }
            check(error.detailsAndClose().message == details.message) { "Kotlin detailed consuming description" }
            rejected(Status.STALE_VALUE, "Kotlin detailed description closes original") { error.value!!.string() }
            rejected(Status.STALE_VALUE, "Kotlin details reject a consumed original") { error.details() }
        }
        try {
            engine.evaluate("function namedFailure(){throw new Error('failure')} namedFailure()", "kotlin-stack.js")
            error("Kotlin stack snapshot source")
        } catch (error: JsBayException) {
            val details = error.details()
            check(details.stackTraceString?.contains("namedFailure") == true) { "Kotlin stack snapshot keeps frames" }
            check(
                details.stackTraceString?.contains("kotlin-stack.js") == true,
            ) { "Kotlin stack snapshot keeps filename" }
            check(error.describeDetailedAndClose().contains("namedFailure")) { "Kotlin detailed display prefers stack" }
            rejected(Status.STALE_VALUE, "Kotlin detailed display closes original") { error.value!!.string() }
        }
        try {
            engine.evaluate(
                "throw ({message:'display marker', stack:'frameOne\\nframeTwo'})",
                "kotlin-display-marker.js",
            )
            error("Kotlin detailed display marker source")
        } catch (error: JsBayException) {
            check(error.describeDetailedAndClose() == "display marker\nframeOne\nframeTwo") {
                "Kotlin detailed display keeps a message missing from stack"
            }
            rejected(Status.STALE_VALUE, "Kotlin detailed display marker closes original") { error.value!!.string() }
        }
        try {
            engine.evaluate(
                "throw ({message:'repeated marker', stack:'Error: repeated marker\\nframe'})",
                "kotlin-display-repeat.js",
            )
            error("Kotlin repeated display marker source")
        } catch (error: JsBayException) {
            check(error.describeDetailedAndClose() == "Error: repeated marker\nframe") {
                "Kotlin detailed display avoids repeating message in stack"
            }
        }
        try {
            engine.evaluate(
                "throw Object.defineProperty(new Error('failure'), 'stack', {get(){throw 1}})",
                "kotlin-stack-getter.js",
            )
            error("Kotlin throwing stack getter source")
        } catch (error: JsBayException) {
            check(error.details().stackTraceString == null) { "Kotlin throwing stack getter falls back" }
            error.value!!.close()
        }
        try {
            engine.evaluate("throw {message:'alias', sourceURL:'alias.js', line:4, column:2}", "kotlin-alias.js")
            error("Kotlin exception alias source")
        } catch (error: JsBayException) {
            val details = error.details()
            check(details.fileName == "alias.js" && details.lineNumber == 4 && details.columnNumber == 2) {
                "Kotlin exception location aliases"
            }
            error.value!!.close()
        }
        try {
            engine.evaluate("throw {toString(){throw 5}}", "kotlin-description-failure.js")
            error("Kotlin description fallback source")
        } catch (error: JsBayException) {
            check(error.details().message == "JavaScript exception") { "Kotlin failed message conversion fallback" }
            error.value!!.close()
        }
        try {
            engine.evaluate("throw null", "kotlin-null-throw.js")
            error("Kotlin null throw source")
        } catch (error: JsBayException) {
            check(error.details().message == "null") { "Kotlin null throw details" }
            error.value!!.close()
        }
        try {
            engine.evaluate("throw {message:'invalid', line:1.5, column:2147483648}", "kotlin-invalid-location.js")
            error("Kotlin invalid location source")
        } catch (error: JsBayException) {
            val details = error.details()
            check(
                details.lineNumber == null && details.columnNumber == null,
            ) { "Kotlin invalid location values are omitted" }
            error.value!!.close()
        }
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
                val originalKind = thisValue.kind()
                rejected(
                    Status.INVALID_ARGUMENT,
                    "Kotlin borrowed exception text",
                ) { JsBayException(Status.EXCEPTION, thisValue).describeAndClose() }
                rejected(Status.INVALID_ARGUMENT, "Kotlin borrowed exception details") {
                    JsBayException(Status.EXCEPTION, thisValue).detailsAndClose()
                }
                check(thisValue.kind() == originalKind) { "Kotlin rejected consume preserves callback value" }
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
        val wrongThreadDetailsException =
            try {
                engine.evaluate("throw new Error('wrong thread details')", "kotlin-wrong-thread-details.js")
                error("Kotlin wrong-thread details source")
            } catch (exception: JsBayException) {
                exception
            }
        var wrongThreadDetails: Throwable? = null
        val detailsWorker =
            Thread {
                try {
                    wrongThreadDetailsException.details()
                } catch (failure: Throwable) {
                    wrongThreadDetails =
                        failure
                }
            }
        detailsWorker.start()
        detailsWorker.join()
        val wrongThreadDetailsFailure = wrongThreadDetails as? JsBayException
        check(wrongThreadDetailsFailure?.status == Status.WRONG_THREAD) {
            "Kotlin exception details reject a foreign thread"
        }
        check(wrongThreadDetailsException.value!!.get("message").use { it.string() } == "wrong thread details") {
            "Kotlin wrong-thread details preserves original exception"
        }
        wrongThreadDetailsException.value!!.close()
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
    run {
        val looper = android.os.Looper.myLooper() ?: error("Kotlin due-flush tests require a prepared Looper")
        val handler = android.os.Handler(looper)
        val ran =
            java.util.concurrent.atomic
                .AtomicInteger(0)
        val chain = 64
        repeat(chain) { handler.post { ran.incrementAndGet() } }
        advanceCurrentLooper(0)
        check(ran.get() == chain) { "Kotlin due-flush completes a finite delay-0 chain: ${ran.get()}" }
        val hasAdvanceBy =
            try {
                looper.javaClass.getMethod("advanceBy", Long::class.javaPrimitiveType)
                true
            } catch (_: NoSuchMethodException) {
                false
            }
        // The iteration cap is the device MessageQueue pump only. The host stub still uses advanceBy and is not the unbounded-flush path.
        if (!hasAdvanceBy) {
            val keepGoing =
                java.util.concurrent.atomic
                    .AtomicBoolean(true)
            val livelock =
                java.util.concurrent.atomic
                    .AtomicInteger(0)
            val tick =
                object : Runnable {
                    override fun run() {
                        livelock.incrementAndGet()
                        if (keepGoing.get()) {
                            handler.post(this)
                        }
                    }
                }
            handler.post(tick)
            try {
                advanceCurrentLooper(0)
                error("advanceCurrentLooper should reject a delay-0 livelock at the due-flush cap")
            } catch (error: IllegalStateException) {
                check(error.message.orEmpty().contains("due-flush cap")) {
                    "Kotlin due-flush cap error: ${error.message}"
                }
            } finally {
                keepGoing.set(false)
                handler.removeCallbacks(tick)
            }
            check(livelock.get() == MAX_DUE_FLUSH_MESSAGES) {
                "Kotlin due-flush cap dispatched ${livelock.get()}, expected $MAX_DUE_FLUSH_MESSAGES"
            }
        }
    }
    Engine(7104).use { submitted ->
        val outcomes = mutableListOf<SubmissionResult>()
        check(submitted.postScript("globalThis.__submitted = 40 + 2", "submission-ok.js") { outcomes += it }) {
            "Kotlin postScript admission"
        }
        check(submitted.postScript("throw new Error('submission')", "submission-error.js") { outcomes += it }) {
            "Kotlin exception submission admission"
        }
        check(submitted.postFence(completion = { outcomes += it })) { "Kotlin postFence admission" }
        advanceCurrentLooper(100)
        check(
            outcomes.map { it.status } ==
                listOf(SubmissionStatus.COMPLETED, SubmissionStatus.EXCEPTION, SubmissionStatus.COMPLETED),
        ) {
            "Kotlin FIFO submission outcomes: $outcomes"
        }
        submitted.evaluate("__submitted", "submission-result.js").use { check(it.number() == 42.0) }
        check(submitted.beginShutdown(1_000)) { "Kotlin beginShutdown admission" }
        check(submitted.postFence(sealShutdown = true) { outcomes += it }) { "Kotlin sealing fence admission" }
        advanceCurrentLooper(100)
        check(submitted.shutdownStatus()?.phase == ShutdownPhase.DRAINED) { "Kotlin shutdown drains through fence" }
        check(!submitted.postScript("1", "submission-rejected.js")) { "Kotlin sealed shutdown rejects new scripts" }
    }
    Engine(7105).use { busy ->
        val outcomes = mutableListOf<SubmissionResult>()
        val entered = java.util.concurrent.CountDownLatch(1)
        busy
            .bind("submissionBusyEntered") { _, _ ->
                entered.countDown()
                busy.undefined()
            }.use {
                check(
                    busy.postScript("submissionBusyEntered(); for (;;) {}", "submission-busy.js") { outcomes += it },
                ) {
                    "Kotlin busy submission admission"
                }
                val controller =
                    Thread {
                        check(
                            entered.await(1, java.util.concurrent.TimeUnit.SECONDS),
                        ) { "Kotlin busy submission entered" }
                        check(busy.beginShutdown(20)) { "Kotlin foreign-thread beginShutdown admission" }
                    }
                controller.start()
                advanceCurrentLooper(200)
                controller.join()
            }
        check(outcomes.singleOrNull()?.status == SubmissionStatus.CANCELLED) {
            "Kotlin foreign-thread shutdown cancels a running submission: $outcomes"
        }
        check(busy.shutdownStatus()?.phase == ShutdownPhase.CANCELLED) {
            "Kotlin foreign-thread shutdown terminal phase"
        }
    }
    runKotlinSubmissionOperations()
    val closed = Engine(mainInstanceId)
    closed.close()
    Engine(mainInstanceId).use { replacement ->
        replacement.evaluate("40+2", "kotlin-reused-id.js").use { result ->
            check(!closed.requestInterrupt()) { "Kotlin closed Engine requestInterrupt rejects reused id" }
            check(result.number() == 42.0) { "Kotlin replacement Engine remains runnable" }
        }
    }
}

private fun runKotlinSubmissionOperations() {
    DedicatedEngineThread.start(7104).use { dedicated ->
        val outcomes = mutableListOf<SubmissionResult>()
        val fence = CountDownLatch(1)
        val sealed = CountDownLatch(1)
        dedicated.runOnOwner { submitted ->
            check(submitted.postScript("globalThis.__submitted = 40 + 2", "submission-ok.js") { outcomes += it }) {
                "Kotlin postScript admission"
            }
            check(submitted.postScript("throw new Error('submission')", "submission-error.js") { outcomes += it }) {
                "Kotlin exception submission admission"
            }
            check(
                submitted.postFence {
                    outcomes += it
                    fence.countDown()
                },
            ) { "Kotlin postFence admission" }
        }
        check(fence.await(5, TimeUnit.SECONDS)) { "Kotlin submission fence completed" }
        dedicated.runOnOwner { submitted ->
            check(
                outcomes.map { it.status } ==
                    listOf(SubmissionStatus.COMPLETED, SubmissionStatus.EXCEPTION, SubmissionStatus.COMPLETED),
            ) {
                "Kotlin FIFO submission outcomes: $outcomes"
            }
            submitted.evaluate("__submitted", "submission-result.js").use { check(it.number() == 42.0) }
            check(submitted.beginShutdown(1_000)) { "Kotlin beginShutdown admission" }
            check(submitted.postFence(sealShutdown = true) { sealed.countDown() }) { "Kotlin sealing fence admission" }
        }
        check(sealed.await(5, TimeUnit.SECONDS)) { "Kotlin sealing fence completed" }
        dedicated.runOnOwner { submitted ->
            check(submitted.shutdownStatus()?.phase == ShutdownPhase.DRAINED) { "Kotlin shutdown drains through fence" }
            check(!submitted.postScript("1", "submission-rejected.js")) { "Kotlin sealed shutdown rejects new scripts" }
        }
    }
    DedicatedEngineThread.start(7105).use { dedicated ->
        val outcomes = mutableListOf<SubmissionResult>()
        val entered = CountDownLatch(1)
        val completed = CountDownLatch(1)
        dedicated.runOnOwner { busy ->
            check(busy.setExecutionBudget(5_000)) { "Kotlin busy submission budget" }
            busy
                .bind("submissionBusyEntered") { _, _ ->
                    entered.countDown()
                    busy.undefined()
                }.close()
            check(
                busy.postScript("submissionBusyEntered(); for (;;) {}", "submission-busy.js") {
                    outcomes += it
                    completed.countDown()
                },
            ) { "Kotlin busy submission admission" }
        }
        check(entered.await(5, TimeUnit.SECONDS)) { "Kotlin busy submission entered" }
        check(dedicated.engine.beginShutdown(20)) { "Kotlin foreign-thread beginShutdown admission" }
        check(completed.await(5, TimeUnit.SECONDS)) { "Kotlin busy submission completed" }
        dedicated.runOnOwner { busy ->
            check(outcomes.singleOrNull()?.status == SubmissionStatus.CANCELLED) {
                "Kotlin foreign-thread shutdown cancels a running submission: $outcomes"
            }
            check(busy.shutdownStatus()?.phase == ShutdownPhase.CANCELLED) {
                "Kotlin foreign-thread shutdown terminal phase"
            }
        }
    }
    runKotlinDedicatedThreadParityTests()
}

private fun runKotlinDedicatedThreadParityTests() {
    DedicatedEngineThread(7106).use { dedicated ->
        check(dedicated.lifecycleState == DedicatedEngineThreadState.RUNNING) { "Kotlin initial lifecycle running" }
        check(!dedicated.isClosing && !dedicated.isClosed) { "Kotlin initial isClosing/isClosed" }
        val nestedResult =
            dedicated.runOnOwner { engine1 ->
                dedicated.runOnOwner { engine2 ->
                    check(engine1.id == engine2.id)
                    "nested-ok"
                }
            }
        check(nestedResult == "nested-ok") { "Kotlin nested runOnOwner executes inline" }
        check(dedicated.setExecutionTimeLimit(10_000L)) { "Kotlin dedicated setExecutionTimeLimit" }
        check(dedicated.setExecutionBudget(5_000L)) { "Kotlin dedicated setExecutionBudget" }
        check(dedicated.setMemoryLimit(10_000_000L)) { "Kotlin dedicated setMemoryLimit" }
        check(dedicated.clearInterrupt()) { "Kotlin dedicated clearInterrupt" }
    }
    val loopStarted = CountDownLatch(1)
    val loopDedicated = DedicatedEngineThread.start(7107)
    val loopThread =
        Thread {
            try {
                loopDedicated.runOnOwner { engine ->
                    engine
                        .bind("loopNotify") { _, _ ->
                            loopStarted.countDown()
                            engine.undefined()
                        }.close()
                    engine.evaluate("loopNotify(); while (true) {}", "infinite.js").close()
                }
            } catch (_: Throwable) {
                // Expected interruption/cancellation on close.
            }
        }
    loopThread.start()
    check(loopStarted.await(5, TimeUnit.SECONDS)) { "Kotlin infinite loop started" }
    loopDedicated.close(5_000L)
    loopThread.join(5_000)
    check(!loopThread.isAlive) { "Kotlin infinite loop thread terminated on close" }

    val queuedDrainDedicated = DedicatedEngineThread.start(7108)
    val queuedDrainResult = AtomicBoolean(false)
    queuedDrainDedicated.post {
        val value = queuedDrainDedicated.engine.evaluate("21 + 21", "drain.js")
        if (value.number() == 42.0) {
            queuedDrainResult.set(true)
        }
        value.close()
    }
    // A foreign bounded close cancels an active job; queue graceful close after the evaluation on the owner.
    queuedDrainDedicated.runOnOwner { queuedDrainDedicated.close(5_000L) }
    queuedDrainDedicated.close(5_000L)
    check(queuedDrainResult.get()) { "Kotlin queued evaluations drain on close" }

    val timeoutDedicated = DedicatedEngineThread.start(7110)
    val timeoutEngine = timeoutDedicated.engine
    val timeoutOwner = timeoutDedicated.runOnOwner { Thread.currentThread() }
    val timeoutEntered = CountDownLatch(1)
    val timeoutRelease = CountDownLatch(1)
    check(
        timeoutDedicated.post {
            timeoutEntered.countDown()
            check(timeoutRelease.await(5, TimeUnit.SECONDS)) { "Kotlin blocked owner released" }
        },
    )
    check(timeoutEntered.await(5, TimeUnit.SECONDS)) { "Kotlin blocked owner entered" }
    try {
        timeoutDedicated.close(1L)
        error("Kotlin blocked creator cannot acknowledge close")
    } catch (_: DedicatedEngineThreadTimeoutException) {
        check(timeoutEngine.closeStatus() == CloseStatus.PENDING) { "Kotlin close timeout remains pending" }
        check(
            timeoutDedicated.lifecycleState == DedicatedEngineThreadState.CLOSING,
        ) { "Kotlin pending drain stays closing" }
        check(timeoutDedicated.isClosing && !timeoutDedicated.isClosed) { "Kotlin pending drain is not closed" }
        check(
            !timeoutDedicated.post {
                error("Closing dedicated thread admitted new work")
            },
        ) { "Kotlin closing rejects new work" }
        try {
            timeoutDedicated.runOnOwner { }
            error("Closing dedicated thread admitted synchronous work")
        } catch (failure: JsBayException) {
            check(failure.status == Status.INSTANCE_NOT_FOUND) { "Kotlin closing rejects foreign runOnOwner" }
        }
        val asyncError = AtomicReference<Throwable?>(null)
        val requester =
            Thread {
                try {
                    timeoutDedicated.close()
                } catch (failure: Throwable) {
                    asyncError.set(failure)
                }
            }
        requester.start()
        requester.join(1_000)
        check(!requester.isAlive && asyncError.get() == null) { "Kotlin default close does not wait for creator" }
        check(timeoutDedicated.lifecycleState == DedicatedEngineThreadState.CLOSING) {
            "Kotlin repeated close preserves pending state"
        }
    } finally {
        timeoutRelease.countDown()
    }
    timeoutOwner.join(5_000)
    check(!timeoutOwner.isAlive) { "Kotlin timed-out close owner exits after drain" }
    check(timeoutEngine.closeStatus() == CloseStatus.COMPLETE) { "Kotlin job cleanup preserves creator drain" }
    check(
        timeoutDedicated.lifecycleState == DedicatedEngineThreadState.CLOSED,
    ) { "Kotlin drained owner publishes closed" }
    check(timeoutDedicated.isClosed && !timeoutDedicated.isClosing) { "Kotlin drained owner lifecycle flags" }

    val userInterruptDedicated = DedicatedEngineThread.start(7109)
    val interruptObserved = AtomicBoolean(false)
    val userInterruptDone = CountDownLatch(1)
    userInterruptDedicated.post {
        userInterruptDedicated.engine.requestInterrupt()
    }
    userInterruptDedicated.post {
        val engine = userInterruptDedicated.engine
        try {
            engine.evaluate("while (true) {}", "user_interrupt.js").close()
        } catch (e: JsBayException) {
            if (e.status == Status.EXCEPTION) {
                interruptObserved.set(true)
            }
        } finally {
            engine.clearInterrupt()
            userInterruptDone.countDown()
        }
    }
    check(userInterruptDone.await(5, TimeUnit.SECONDS)) { "Kotlin user interrupt job completed" }
    userInterruptDedicated.close(5_000L)
    check(interruptObserved.get()) { "Kotlin user interrupt preserved across jobs" }

    val directInvokeDedicated = DedicatedEngineThread(7110)
    check(directInvokeDedicated.lifecycleState == DedicatedEngineThreadState.RUNNING) {
        "Kotlin DedicatedEngineThread invoke lifecycle running"
    }
    check(!directInvokeDedicated.isClosing && !directInvokeDedicated.isClosed) {
        "Kotlin dedicated initial isClosing/isClosed"
    }
    directInvokeDedicated.close(5_000L)
    check(
        directInvokeDedicated.lifecycleState == DedicatedEngineThreadState.CLOSED,
    ) { "Kotlin dedicated lifecycle closed" }
    check(directInvokeDedicated.isClosed && !directInvokeDedicated.isClosing) {
        "Kotlin dedicated closed isClosed/isClosing"
    }
}
