'use strict'

/* Executes against the same C++ N-API bridge as Harmony. Node supplies only the N-API host; it does not replace or mock any bridge or core behavior. */
const native = require(process.env.JSBAY_HARMONY_NODE)

function expect(condition, message) {
  if (!condition) throw new Error(message)
}
function expectThrow(operation, message) {
  let thrown = false
  try { operation() } catch (_) { thrown = true }
  expect(thrown, message)
}
function expectStatus(operation, status, message) {
  try { operation() } catch (error) {
    expect(error.status === status, `${message}: expected ${status}, received ${error.status}`)
    return
  }
  throw new Error(`${message}: did not throw`)
}
function release(value) { if (value) native.release(value) }

const Status = { INVALID_ARGUMENT: 2, INSTANCE_NOT_FOUND: 4, STALE_VALUE: 5 }
function text(value) { return new TextDecoder().decode(native.toUtf8(value)) }
function json(value) { return new TextDecoder().decode(native.toJson(value)) }
function expectJsError(operation, name, message) {
  try { operation() } catch (error) {
    expect(error.value, `${message}: exception must contain a Value`)
    const actual = native.get(error.value, 'name')
    try { expect(text(actual) === name, `${message}: expected ${name}, received ${text(actual)}`) }
    finally { release(actual); release(error.value) }
    return
  }
  throw new Error(`${message}: did not throw`)
}
function evaluated(engine, source, filename, body) {
  const value = native.evaluate(engine, source, filename)
  try { body(value) } finally { release(value) }
}

function checkObjectOperations(engine) {
  evaluated(engine, '(function P(x) { this.x = x })', 'construct.js', (point) => {
    const answer = native.newNumber(engine, 42)
    try {
      const built = native.construct(point, [answer])
      try {
        const x = native.get(built, 'x')
        try { expect(native.toNumber(x) === 42, 'construct passes arguments') }
        finally { release(x) }
        expect(native.instanceOf(built, point) === true, 'constructed value is instanceOf its constructor')
      } finally { release(built) }
    } finally { release(answer) }
  })
  evaluated(engine, '(function Q() { this.n = arguments.length })', 'construct-n.js', (counter) => {
    const built = native.construct(counter, [])
    try {
      const n = native.get(built, 'n')
      try { expect(native.toNumber(n) === 0, 'construct with an empty argument list') }
      finally { release(n) }
    } finally { release(built) }
  })
  evaluated(engine, "(function B() { throw new Error('ctor boom') })", 'ctor-boom.js', (boom) => {
    expectJsError(() => native.construct(boom, []), 'Error', 'construct propagates constructor throw')
  })
  evaluated(engine, '(() => 1)', 'arrow-construct.js', (arrow) => {
    expectJsError(() => native.construct(arrow, []), 'TypeError', 'construct rejects non-constructor')
  })

  evaluated(engine, '({ a: 1 })', 'has.js', (target) => {
    expect(native.has(target, 'a') === true, 'has own property')
    expect(native.has(target, 'toString') === true, 'has inherited property')
    expect(native.has(target, 'zzz') === false, 'has missing property is false')
  })
  const number = native.newNumber(engine, 42)
  try { expectJsError(() => native.has(number, 'a'), 'TypeError', 'has rejects non-object') }
  finally { release(number) }
  evaluated(engine, "new Proxy({}, { has(t, k) { throw new Error('trap') } })", 'has-trap.js', (trap) => {
    expectJsError(() => native.has(trap, 'a'), 'Error', 'has propagates Proxy trap throw')
  })

  evaluated(engine, "(() => { const o = { a: 1 }; Object.defineProperty(o, 'fixed', { value: 1, configurable: false }); return o })()", 'delete.js', (target) => {
    expect(native.deleteKey(target, 'a') === true, 'delete configurable property')
    expect(native.has(target, 'a') === false, 'deleted property is gone')
    expect(native.deleteKey(target, 'fixed') === false, 'delete non-configurable reports false')
    expect(native.has(target, 'fixed') === true, 'non-configurable property survives delete')
    expect(native.deleteKey(target, 'missing') === true, 'delete missing property is true')
  })
  const undefinedTarget = native.undefined(engine)
  try { expectJsError(() => native.deleteKey(undefinedTarget, 'a'), 'TypeError', 'delete rejects undefined') }
  finally { release(undefinedTarget) }
  const primitiveText = native.newString(engine, 'abc')
  try { expect(native.deleteKey(primitiveText, 'zz') === true, 'delete converts primitive with ToObject') }
  finally { release(primitiveText) }

  evaluated(engine, "(() => { const o = { b: 1, 2: 1, a: 1, 1: 1 }; Object.defineProperty(o, 'hidden', { value: 1, enumerable: false }); o[Symbol('s')] = 1; return o })()", 'keys.js', (target) => {
    const keys = native.keys(target)
    try { expect(json(keys) === '["1","2","b","a"]', `keys order and filtering: ${json(keys)}`) }
    finally { release(keys) }
  })
  evaluated(engine, 'Object.create({ inherited: 1 })', 'keys-inherited.js', (target) => {
    const keys = native.keys(target)
    try { expect(json(keys) === '[]', 'keys excludes inherited keys') }
    finally { release(keys) }
  })
  evaluated(engine, "new Proxy({}, { ownKeys() { return ['z', 'y'] }, getOwnPropertyDescriptor() { return { value: 1, enumerable: true, configurable: true } } })", 'keys-proxy.js', (target) => {
    const keys = native.keys(target)
    try { expect(json(keys) === '["z","y"]', `keys follows Proxy ownKeys order: ${json(keys)}`) }
    finally { release(keys) }
  })
  const nullTarget = native.null(engine)
  try { expectJsError(() => native.keys(nullTarget), 'TypeError', 'keys rejects null') }
  finally { release(nullTarget) }

  evaluated(engine, '(class { static [Symbol.hasInstance](v) { return v === 7 } })', 'has-instance.js', (custom) => {
    const seven = native.newNumber(engine, 7)
    const eight = native.newNumber(engine, 8)
    try {
      expect(native.instanceOf(seven, custom) === true, 'instanceOf honors Symbol.hasInstance')
      expect(native.instanceOf(eight, custom) === false, 'instanceOf Symbol.hasInstance can decline')
    } finally { release(seven); release(eight) }
  })
  evaluated(engine, '[]', 'instance-array.js', (array) => {
    evaluated(engine, 'Array', 'instance-array-class.js', (arrayClass) => {
      expect(native.instanceOf(array, arrayClass) === true, 'instanceOf matches prototype chain')
    })
    evaluated(engine, 'Function', 'instance-function-class.js', (functionClass) => {
      expect(native.instanceOf(array, functionClass) === false, 'instanceOf rejects unrelated constructor')
    })
    evaluated(engine, '({})', 'instance-plain.js', (plain) => {
      expectJsError(() => native.instanceOf(array, plain), 'TypeError', 'instanceOf rejects non-callable constructor')
    })
  })
}

const engine = native.create(1001)
let escaped
let borrowed
try {
  const binding = native.bind(engine, 'scopeProbe', (_this, input) => {
    borrowed = input
    escaped = native.retain(input)
    for (let index = 0; index < 1024; index += 1) native.newObject(engine)
    if (global.gc) global.gc()
    return native.newNumber(engine, native.toNumber(input) + 1)
  })
  try {
    const callbackResult = native.evaluate(engine, 'scopeProbe(41)', 'scope.js')
    try { expect(native.toNumber(callbackResult) === 42, 'callback result') }
    finally { release(callbackResult) }
  } finally { release(binding) }
  expect(native.toNumber(escaped) === 41, 'retained borrowed value escapes callback')
  release(escaped); escaped = undefined
  expectThrow(() => native.toNumber(borrowed), 'borrowed callback value expires')

  const object = native.evaluate(engine, '({ answer: 42 })', 'property.js')
  try {
    const answer = native.get(object, 'answer')
    try { expect(native.toNumber(answer) === 42, 'property result') }
    finally { release(answer) }
  } finally { release(object) }

  const recursive = native.bind(engine, 'recurse', (_this, argument) => {
    const remaining = native.toNumber(argument)
    if (remaining === 0) return native.newNumber(engine, 1)
    const globalValue = native.global(engine)
    const functionValue = native.get(globalValue, 'recurse')
    const next = native.newNumber(engine, remaining - 1)
    try { return native.call(functionValue, globalValue, [next]) }
    finally { release(globalValue); release(functionValue); release(next) }
  })
  try {
    const recursiveResult = native.evaluate(engine, 'recurse(3)', 'recursive.js')
    try { expect(native.toNumber(recursiveResult) === 1, 'nested callback scope') }
    finally { release(recursiveResult) }
  } finally { release(recursive) }

  let arbitraryThrow = false
  try { native.evaluate(engine, 'throw { code: 7 }', 'throw.js') }
  catch (error) {
    const code = native.get(error.value, 'code')
    try { arbitraryThrow = native.toNumber(code) === 7 }
    finally { release(code); release(error.value) }
  }
  expect(arbitraryThrow, 'arbitrary JavaScript exception value')
  expectStatus(() => native.toBool({}), Status.INVALID_ARGUMENT, 'invalid Value wrapper')
  const undefinedValue = native.undefined(engine)
  try { expectStatus(() => native.toJson(undefinedValue), Status.INVALID_ARGUMENT, 'JSON undefined') }
  finally { release(undefinedValue) }

  const setter = native.evaluate(engine, '(() => { const o = {}; Object.defineProperty(o, "x", { set() { throw 7 } }); return o })()', 'setter.js')
  const seven = native.newNumber(engine, 1)
  try {
    let setterThrow = false
    try { native.set(setter, 'x', seven) } catch (error) {
      expect(error.value, 'setter exception must contain a Value')
      try { setterThrow = native.toNumber(error.value) === 7 }
      finally { release(error.value) }
    }
    expect(setterThrow, 'setter must preserve primitive throw')
  } finally { release(setter); release(seven) }
  const stringer = native.evaluate(engine, '({ toString() { throw 7 } })', 'to-string.js')
  try {
    let stringThrow = false
    try { native.toUtf8(stringer) } catch (error) {
      expect(error.value, 'toUtf8 exception must contain a Value')
      try { stringThrow = native.toNumber(error.value) === 7 }
      finally { release(error.value) }
    }
    expect(stringThrow, 'toUtf8 must preserve primitive throw')
  } finally { release(stringer) }

  const setup = native.evaluate(engine, 'globalThis.__loop=[0,0]; queueMicrotask(()=>__loop[0]=1); setTimeout(()=>{__loop[1]=1;stopNativeLoop()},10); 0', 'loop.js')
  release(setup)
  const microtask = native.evaluate(engine, '__loop[0]', 'microtask.js')
  try { expect(native.toNumber(microtask) === 1, 'microtask checkpoint') }
  finally { release(microtask) }
  const stopNativeBinding = native.bind(engine, 'stopNativeLoop', () => {
    native.stopLoop(engine)
    return native.newUndefined(engine)
  })
  native.runLoop(engine)
  release(stopNativeBinding)
  const timer = native.evaluate(engine, '__loop[1]', 'timer.js')
  try { expect(native.toNumber(timer) === 1, 'self-driven timer') }
  finally { release(timer) }

  let syncRequest = 0n
  const syncInline = native.bindSync(engine, 'syncInline', 100n, (requestId, _this, args) => {
    expect(typeof requestId === 'bigint', 'sync request ID must be bigint')
    expect(native.toNumber(args[0]) === 41, 'sync callback argument')
    expect(native.completeSync(requestId, 0, 0, '41') === 0, 'sync inline completion')
  })
  try {
    const result = native.evaluate(engine, 'Number(syncInline(41)) + 1', 'sync-inline.js')
    try { expect(native.toNumber(result) === 42, 'sync inline result') }
    finally { release(result) }
  } finally { release(syncInline) }

  const syncReject = native.bindSync(engine, 'syncReject', 100n, (requestId) => {
    expect(native.completeSync(requestId, 1, 0, 'sync rejected') === 0, 'sync rejection completion')
  })
  try {
    const result = native.evaluate(engine, 'try { syncReject() } catch (error) { error }', 'sync-reject.js')
    try { expect(new TextDecoder().decode(native.toUtf8(result)).includes('sync rejected'), 'sync rejection value') }
    finally { release(result) }
  } finally { release(syncReject) }

  const syncTimeout = native.bindSync(engine, 'syncTimeout', 10n, (requestId) => { syncRequest = requestId })
  try {
    expectThrow(() => native.evaluate(engine, 'syncTimeout()', 'sync-timeout.js'), 'sync timeout throws')
    expect(native.completeSync(syncRequest, 0, 0, '41') === Status.STALE_VALUE, 'late completion after timeout is stale')
    expect(native.completeSync((1n << 64n) - 1n, 0, 0, '41') === Status.STALE_VALUE, 'unknown bigint completion is stale')
    expect(native.completeSync(syncRequest, 7, 0, '41') === Status.INVALID_ARGUMENT, 'invalid sync outcome rejects')
  } finally { release(syncTimeout) }

  const { Worker } = require('worker_threads')
  let syncWorker
  const syncCrossWorker = native.bindSync(engine, 'syncCrossWorker', 1000n, (requestId) => {
    syncWorker = new Worker(`const { workerData } = require('worker_threads'); const native = require(workerData.addon); if (native.completeSync(BigInt(workerData.requestId), 0, 0, '41') !== 0) process.exit(2);`, { eval: true, workerData: { addon: process.env.JSBAY_HARMONY_NODE, requestId: requestId.toString() } })
  })
  try {
    const result = native.evaluate(engine, 'Number(syncCrossWorker()) + 1', 'sync-cross-worker.js')
    try { expect(native.toNumber(result) === 42, 'worker-thread completion') }
    finally { release(result) }
  } finally { release(syncCrossWorker) }
  if (syncWorker) syncWorker.unref()

  /* The Worker deliberately omits Engine.close(). Its idle loop must release the platform keepalive so environment cleanup can detach before disposing callback data. */
  const cleanupWorker = new Worker(`const { workerData } = require('worker_threads'); const native = require(workerData.addon); const engine = native.create(1006); native.attachLoop(engine, (delay, generation) => setTimeout(() => native.runLoopTask(engine, generation), delay));`, { eval: true, workerData: { addon: process.env.JSBAY_HARMONY_NODE } })
  cleanupWorker.on('exit', (code) => {
    if (code !== 0) process.nextTick(() => { throw new Error(`wake cleanup Worker exit ${code}`) })
  })

  const source = new Uint8Array([1, 2, 3, 4])
  const visible = new Uint8Array(source.buffer, 1, 2)
  const binary = native.newArrayBuffer(engine, visible)
  try {
    source[1] = 99
    const copied = new Uint8Array(native.copyBuffer(binary))
    expect(copied.length === 2 && copied[0] === 2 && copied[1] === 3, 'typed array visible byte copy')
  } finally { release(binary) }
  const typed = native.evaluate(engine, 'new Uint8Array([8, 7, 6]).subarray(1)', 'typed.js')
  const dataView = native.evaluate(engine, 'new DataView(new Uint8Array([5, 4, 3]).buffer, 1, 2)', 'dataview.js')
  try {
    expect(Array.from(new Uint8Array(native.copyBuffer(typed))).join(',') === '7,6', 'JavaScript TypedArray visible byte copy')
    expect(Array.from(new Uint8Array(native.copyBuffer(dataView))).join(',') === '4,3', 'JavaScript DataView visible byte copy')
  } finally { release(typed); release(dataView) }

  expect(native.requestInterrupt(engine) === true, 'interrupt can be requested')
  expect(native.clearInterrupt(engine) === true, 'clearInterrupt accepts its single Engine argument')
  expect(native.setExecutionTimeLimit(engine, 0n) === true, 'uint64 limit accepts')
  expectThrow(() => native.setMemoryLimit(engine, -1n), 'negative uint64 limit rejects')

  checkObjectOperations(engine)

  const other = native.create(1002)
  try {
    const foreign = native.newNumber(engine, 1)
    const target = native.newObject(other)
    try {
      expectStatus(() => native.set(target, 'x', foreign), Status.STALE_VALUE, 'cross-engine Value')
      const constructor = native.evaluate(other, '(function () {})', 'cross-construct.js')
      try {
        expectStatus(() => native.construct(constructor, [foreign]), Status.STALE_VALUE, 'cross-engine construct argument')
        expectStatus(() => native.instanceOf(target, foreign), Status.STALE_VALUE, 'cross-engine instanceOf constructor')
      } finally { release(constructor) }
    } finally { release(foreign); release(target) }
  } finally { native.close(other) }

  const closingEngine = native.create(1003)
  let closeRequest = 0n
  const closeSync = native.bindSync(closingEngine, 'syncClose', 100n, (requestId) => {
    closeRequest = requestId
    native.close(closingEngine)
  })
  try {
    expectThrow(() => native.evaluate(closingEngine, 'syncClose()', 'sync-close.js'), 'close cancels active sync request')
    expect(native.completeSync(closeRequest, 0, 0, '41') === Status.STALE_VALUE, 'late completion after close is stale')
  } finally {
    try { release(closeSync) } catch (_) {}
    try { native.close(closingEngine) } catch (_) {}
  }

  const loopEngine = native.create(1004)
  let timerCalls = 0
  let autoTimer
  native.attachLoop(loopEngine, (delay, generation) => {
    clearTimeout(autoTimer)
    autoTimer = setTimeout(() => native.runLoopTask(loopEngine, generation), delay)
  })
  let completeAutomatic
  const automaticDone = new Promise(resolve => { completeAutomatic = resolve })
  const automaticWatchdog = setTimeout(() => { throw new Error('automatic loop did not execute timer') }, 5000)
  const timerBinding = native.bind(loopEngine, 'recordTimer', () => {
    timerCalls += 1
    native.stopLoop(loopEngine)
    completeAutomatic()
    return native.newUndefined(loopEngine)
  })
  release(timerBinding)
  release(native.evaluate(loopEngine, 'setTimeout(recordTimer, 1)', 'automatic-loop.js'))
  automaticDone.then(() => {
    expect(timerCalls === 1, 'attached loop executes timer without manual driving')
    clearTimeout(automaticWatchdog)
    clearTimeout(autoTimer)
    native.close(loopEngine)
    console.log('harmony automatic loop consumer: PASS')
  })

  const blockingEngine = native.create(1005)
  let blockingCalls = 0
  const stopBinding = native.bind(blockingEngine, 'stopLoop', () => {
    blockingCalls += 1
    expect(native.stopLoop(blockingEngine), 'native stop loop')
    return native.newUndefined(blockingEngine)
  })
  release(stopBinding)
  release(native.evaluate(blockingEngine, 'setTimeout(stopLoop, 1)', 'blocking-loop.js'))
  native.runLoop(blockingEngine)
  expect(blockingCalls === 1, 'blocking loop automatically executes its timer')
  native.close(blockingEngine)

  const stale = native.newNumber(engine, 9)
  native.close(engine)
  expectStatus(() => native.toNumber(stale), Status.STALE_VALUE, 'destroy invalidates existing Value')
  console.log('harmony Node N-API consumer: PASS')
} finally {
  if (escaped) { try { release(escaped) } catch (_) {} }
  try { native.close(engine) } catch (_) {}
}
