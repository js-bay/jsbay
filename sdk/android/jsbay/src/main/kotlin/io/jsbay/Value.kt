package io.jsbay

import kotlin.jvm.JvmName
import kotlin.jvm.JvmSynthetic

class Value internal constructor(
    internal val engine: Engine,
    internal var handle: Long,
    private val borrowed: Boolean = false,
) : AutoCloseable {
    private fun live(): Long {
        if (handle == 0L || engine.isClosed()) throw JsBayException(Status.STALE_VALUE)
        engine.checkOwner()
        return handle
    }

    @JvmSynthetic
    @JvmName("callbackHandleForNative")
    internal fun callbackHandleForNative(): Long = live()

    @JvmSynthetic
    @JvmName("callbackEngineForNative")
    internal fun callbackEngineForNative(): Engine = engine

    internal fun invalidateFromScope() {
        handle = 0L
    }

    internal fun requireOwnedForConsume() {
        if (borrowed) {
            throw JsBayException(
                if (handle == 0L) {
                    Status.STALE_VALUE
                } else {
                    Status.INVALID_ARGUMENT
                },
            )
        }
        live()
    }

    fun retain(): Value = engine.wrap(Native.retain(live()), false)

    fun kind(): ValueKind {
        val kind = Native.type(engine, live())
        return ValueKind.entries[kind]
    }

    fun type(): ValueKind = kind()

    fun string(): String = Native.toUtf8(engine, live())

    fun asString(): String = string()

    fun number(): Double = Native.number(engine, live())

    fun bool(): Boolean = Native.bool(engine, live())

    fun json(): String = Native.toJson(engine, live())

    fun get(key: String): Value = engine.wrap(Native.get(live(), engine.text(key)))

    fun set(
        key: String,
        value: Value,
    ) {
        engine.same(value)
        Native.set(engine, live(), engine.text(key), value.live())
    }

    fun bytes(): ByteArray = Native.copyBuffer(engine, live())

    @JvmOverloads fun call(
        thisValue: Value? = null,
        args: List<Value> = emptyList(),
    ): Value {
        val function = live()
        val receiver =
            thisValue ?: engine.undefined()
        try {
            engine.same(receiver)
            args.forEach(engine::same)
            return engine.wrap(Native.call(function, receiver.live(), args.map { it.live() }.toLongArray()))
        } finally {
            if (thisValue == null) {
                receiver.close()
            }
        }
    }

    @JvmOverloads fun construct(args: List<Value> = emptyList()): Value {
        val function = live()
        args.forEach(engine::same)
        return engine.wrap(Native.construct(function, args.map { it.live() }.toLongArray()))
    }

    fun has(key: String): Boolean = engine.flag(Native.has(live(), engine.text(key)))

    fun delete(key: String): Boolean = engine.flag(Native.delete(live(), engine.text(key)))

    fun keys(): Value = engine.wrap(Native.keys(live()))

    fun instanceOf(constructor: Value): Boolean {
        val value = live()
        engine.same(constructor)
        return engine.flag(Native.instanceOf(value, constructor.live()))
    }

    override fun close() {
        if (borrowed) {
            if (handle == 0L) {
                throw JsBayException(Status.STALE_VALUE)
            }
            throw JsBayException(Status.INVALID_ARGUMENT)
        }
        if (handle == 0L) {
            return
        }
        if (engine.isClosed()) {
            handle = 0L
            return
        }
        engine.checkOwner()
        val value = handle
        Native.release(engine, value)
        handle = 0L
    }
}
