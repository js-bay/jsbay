'use strict'

const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const { Worker } = require('node:worker_threads')

const addonPath = process.env.JSBAY_NODE_ADDON
assert.ok(addonPath, 'JSBAY_NODE_ADDON must name the Node-API module')
const addon = require(addonPath)
const { Engine } = addon

function valueOf(error) { return error instanceof Error ? error.message : error }

function withTimeout(promise, label, milliseconds = 300) {
  let timer
  const expiry = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds) })
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer))
}

async function timerMicrotask() {
  const engine = Engine.create({ instanceId: 9601 })
  const started = Date.now()
  const keepAlive = setInterval(() => {}, 1000)
  try {
    assert.equal(await withTimeout(engine.evaluateAsync('new Promise(resolve => setTimeout(() => resolve(42), 5))'), 'guest timer promise'), 42)
    const elapsed = Date.now() - started
    assert.ok(elapsed < 300, `guest timer settlement took ${elapsed}ms`)
  } finally {
    clearInterval(keepAlive)
    engine.close()
  }
}

async function nestedThenable() {
  const engine = Engine.create({ instanceId: 9602 })
  try {
    assert.equal(await engine.evaluateAsync('({ then(resolve) { resolve(Promise.resolve(42)) } })'), 42)
  } finally { engine.close() }
}

function guestThenGetter() {
  const engine = Engine.create({ instanceId: 9603 })
  try {
    assert.throws(() => engine.evaluate('globalThis.reads = 0; ({ get then() { reads++; return undefined } })'))
    assert.equal(engine.evaluate('reads'), 0, 'sync evaluate must not invoke a guest then getter')
  } finally { engine.close() }
}

function explicitUndefined() {
  const engine = Engine.create({ instanceId: 9604 })
  try {
    assert.equal(engine.evaluate('42', undefined), 42)
  } finally { engine.close() }
  const defaultEngine = Engine.create({ instanceId: undefined })
  try { assert.equal(defaultEngine.evaluate('42'), 42) } finally { defaultEngine.close() }
}

function errorProperties() {
  const engine = Engine.create({ instanceId: 9605 })
  try {
    engine.bind('hostError', () => new Error('x'))
    const keys = engine.evaluate('Object.keys(hostError()).sort().join(",")')
    assert.equal(keys, '', 'Error name and stack must remain non-enumerable after conversion')
  } finally { engine.close() }
}

function cleanupPending() {
  const before = addon._testState()
  const engine = Engine.create({ instanceId: 9608 })
  engine.bindAsync('wait', () => new Promise(() => {}))
  engine.evaluate('void wait()')
  assert.equal(addon._testState().pendingCalls, before.pendingCalls + 1, 'guest call reserves a native request')
  addon._testFail('cleanup_pending')
  engine.close()
  assert.equal(addon._testState().pendingCalls, before.pendingCalls, 'cleanup after a pending finalizer releases native request resources')
}

function sparseArray() {
  const engine = Engine.create({ instanceId: 9609 })
  try {
    const value = engine.evaluate('(()=>{ const value=[]; value.length=2147483648; return value })()')
    assert.equal(value.length, 2147483648, 'a sparse guest array keeps its length')
    assert.equal(Object.keys(value).length, 0, 'the sparse array does not materialize elements')
  } finally { engine.close() }
}

async function completionReasons() {
  assert.equal(typeof addon._testFail, 'function', 'completion reasons require the test addon')
  const engine = Engine.create({ instanceId: 9613 })
  try {
    engine.bindAsync('unsupported', () => () => {})
    await assert.rejects(engine.evaluateAsync('unsupported()'), error => {
      assert.match(valueOf(error), /could not convert host completion/)
      assert.doesNotMatch(valueOf(error), /completion handler/)
      return true
    })

    engine.bindAsync('value', () => Promise.resolve(42))
    addon._testFail('create_first')
    assert.equal(await engine.evaluateAsync("value().catch(error => { error.name = 'Changed'; error.message = 'mutated'; return error.name + ':' + error.message })"), 'Changed:mutated')
    addon._testFail('create_first')
    assert.equal(await engine.evaluateAsync("value().catch(error => error.name + ':' + error.message)"), 'Error:could not create host completion handler')
  } finally { engine.close() }
}

async function sharedHandlerError() {
  assert.equal(typeof addon._testFail, 'function', 'shared handler errors require the test addon')
  const engine = Engine.create({ instanceId: 9614 })
  try {
    engine.bindAsync('value', () => Promise.resolve(42))
    addon._testFail('create_first')
    assert.equal(await engine.evaluateAsync("value().catch(error => { error.name = 'Changed'; error.message = 'mutated'; return error.name + ':' + error.message })"), 'Changed:mutated')
    addon._testFail('create_first')
    assert.equal(await engine.evaluateAsync("value().catch(error => error.name + ':' + error.message)"), 'Error:could not create host completion handler')
  } finally { engine.close() }
}

async function flush() {
  for (let index = 0; index < 3; index++) {
    global.gc()
    await new Promise(resolve => setImmediate(resolve))
  }
}

async function timerCloseObserver() {
  const engine = Engine.create({ instanceId: 9615 })
  let inner
  try {
    engine.bind('closeIt', () => engine.close())
    engine.bind('tick', () => { queueMicrotask(() => { inner = engine.evaluateAsync('closeIt(); 1'); void inner.catch(() => {}) }) })
    engine.evaluate('setTimeout(tick, 1)')
    await withTimeout(new Promise(resolve => {
      const poll = setInterval(() => { if (inner) { clearInterval(poll); resolve() } }, 1)
    }), 'timer callback')
    await assert.rejects(withTimeout(inner, 'observer after close'), /JsBay engine closed/)
  } finally { engine.close() }
}

async function synchronousThrowCompletions() {
  assert.equal(typeof global.gc, 'function', 'run this case with --expose-gc')
  const before = addon._testState()
  const engine = Engine.create({ instanceId: 9616 })
  try {
    engine.bindAsync('fail', () => { throw new Error('synchronous host failure') })
    for (let index = 0; index < 100; index++) await assert.rejects(engine.evaluateAsync('fail()'), /synchronous host failure/)
    await flush()
    assert.equal(addon._testState().completions, before.completions, 'synchronous throw releases completion metadata')
  } finally { engine.close() }
}

async function conversionRejects() {
  const engine = Engine.create({ instanceId: 9617 })
  try {
    let thrown
    assert.doesNotThrow(() => { thrown = engine.evaluateAsync('throw Object.create({})') })
    await assert.rejects(withTimeout(thrown, 'thrown unsupported prototype'), error => error instanceof Error)
    await assert.rejects(withTimeout(engine.evaluateAsync('Promise.reject(Object.create({}))'), 'rejected unsupported prototype'), error => error instanceof Error)
  } finally { engine.close() }
}

async function conversionObserverRejects() {
  const engine = Engine.create({ instanceId: 9619 })
  try {
    await assert.rejects(withTimeout(engine.evaluateAsync('Promise.reject(Object.create({}))'), 'rejected unsupported prototype'), error => error instanceof Error)
  } finally { engine.close() }
}

function syncHostThrow() {
  const engine = Engine.create({ instanceId: 9620 })
  try {
    engine.bind('partial', () => { throw { ok: 1, bad() {} } })
    const partial = engine.evaluate("(()=>{try { partial() } catch (error) { return { error: error instanceof Error, ok: Object.hasOwn(error, 'ok'), message: String(error.message || '') } }})()")
    assert.equal(partial.error, true, 'a partially converted thrown object must become an Error')
    assert.equal(partial.ok, false, 'a partial object must not become the guest exception')
    assert.notEqual(partial.message, '', 'the conversion failure must describe the error')

    engine.bind('proxyThrow', () => { throw new Proxy({}, { ownKeys() { throw new Error('real conversion failure') } }) })
    assert.equal(engine.evaluate("(()=>{try { proxyThrow() } catch (error) { return error.message }})()"), 'real conversion failure')

    engine.bind('proxyPartial', () => { throw new Proxy({}, { ownKeys() { throw { ok: 1, bad() {} } } }) })
    const proxyPartial = engine.evaluate("(()=>{try { proxyPartial() } catch (error) { return { error: error instanceof Error, ok: Object.hasOwn(error, 'ok'), message: String(error.message || '') } }})()")
    assert.equal(proxyPartial.error, true, 'a pending Node exception with a partial value must become an Error')
    assert.equal(proxyPartial.ok, false, 'a pending Node exception must not expose a partial object')
    assert.notEqual(proxyPartial.message, '', 'the pending exception conversion must describe the error')
  } finally { engine.close() }
}

function argumentBudget() {
  const engine = Engine.create({ instanceId: 9621 })
  let calls = 0
  try {
    engine.bind('receive', () => { calls++; return 42 })
    const result = engine.evaluate("(()=>{ const text = 'x'.repeat(9 * 1024 * 1024); try { receive(text, text); return 'accepted' } catch (error) { return error instanceof Error ? error.message : 'not-error' } })()")
    assert.notEqual(result, 'accepted', 'two nine-megabyte arguments exceed the per-call conversion budget')
    assert.notEqual(result, 'not-error', 'budget rejection must be an Error')
    assert.equal(calls, 0, 'the host callback must not run after argument conversion rejects')
  } finally { engine.close() }
}

async function callHostFailure() {
  assert.equal(typeof addon._testFail, 'function', 'call-host failure requires the test addon')
  const engine = Engine.create({ instanceId: 9622 })
  try {
    engine.bind('sync', () => 42)
    addon._testFail('call_host')
    assert.equal(engine.evaluate("(()=>{try { sync() } catch (error) { return error instanceof Error && error.message }})()"), 'native callback failed with status 2')

    engine.bindAsync('async', () => 42)
    addon._testFail('call_host')
    await assert.rejects(engine.evaluateAsync('async()'), error => error instanceof Error)
    assert.equal(engine.evaluate('40 + 2'), 42, 'the engine remains usable after a host-call failure')
  } finally { engine.close() }
}

function constructorFailure() {
  const engine = Engine.create({ instanceId: 9624 })
  const descriptor = Object.getOwnPropertyDescriptor(Promise.prototype, 'constructor')
  let calls = 0
  try {
    engine.bindAsync('value', () => { calls++; return 42 })
    Object.defineProperty(Promise.prototype, 'constructor', {
      configurable: true,
      get() { throw new Error('constructor setup failure') }
    })
    const result = engine.evaluate("(()=>{try { const pending = value(); pending.catch(() => {}); return typeof pending.then } catch (error) { return 'threw' }})()")
    assert.equal(result, 'function', 'handler setup failure must surface as a rejected guest Promise')
    assert.equal(calls, 0, 'the application callback must not run when handler setup fails')
  } finally {
    Object.defineProperty(Promise.prototype, 'constructor', descriptor)
    engine.close()
  }
}

function workerFinalizer() {
  return new Promise((resolve, reject) => {
    const worker = new Worker(`
      const { Engine } = require(process.env.JSBAY_NODE_ADDON)
      let engine = Engine.create({ instanceId: 9606 })
      engine.evaluate('1')
      engine = null
      if (typeof global.gc !== 'function') throw new Error('gc unavailable')
      global.gc(); global.gc()
    `, { eval: true })
    const timer = setTimeout(() => { void worker.terminate(); reject(new Error('worker finalizer timed out')) }, 1500)
    worker.once('error', error => { clearTimeout(timer); reject(error) })
    worker.once('exit', code => { clearTimeout(timer); assert.equal(code, 0); resolve() })
  })
}

function workerPendingNaturalExit() {
  return new Promise((resolve, reject) => {
    const worker = new Worker(`
      const { Engine } = require(process.env.JSBAY_NODE_ADDON)
      const engine = Engine.create({ instanceId: 9618 })
      engine.bindAsync('hostPending', () => new Promise(() => {}))
      void engine.evaluateAsync('hostPending()')
      void engine.evaluateAsync('new Promise(() => {})')
    `, { eval: true })
    const timer = setTimeout(() => { void worker.terminate(); reject(new Error('pending worker did not exit')) }, 1500)
    worker.once('error', error => { clearTimeout(timer); reject(error) })
    worker.once('exit', code => { clearTimeout(timer); assert.equal(code, 0); resolve() })
  })
}

async function pendingEngineGc() {
  const pending = createPendingWithoutWrapper()
  let observed
  void pending.then(value => { observed = { value } }, error => { observed = { error } })
  assert.equal(typeof global.gc, 'function', 'run this case with --expose-gc')
  for (let index = 0; index < 8; index++) {
    global.gc()
    await new Promise(resolve => setImmediate(resolve))
  }
  releasePending(42)
  assert.equal(await withTimeout(pending, 'completion after wrapper GC'), 42)
  assert.deepEqual(observed, { value: 42 })
}

let releasePending
function createPendingWithoutWrapper() {
  const engine = (() => {
    const engine = Engine.create({ instanceId: 9607 })
    engine.bindAsync('wait', () => new Promise(resolve => { releasePending = resolve }))
    return engine
  })()
  return engine.evaluateAsync('wait()')
}

function childCase(mode) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--expose-gc', __filename, mode], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    child.stdout.on('data', chunk => { output += chunk })
    child.stderr.on('data', chunk => { output += chunk })
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`${mode} timed out: ${output}`)) }, 1500)
    child.once('error', error => { clearTimeout(timer); reject(error) })
    child.once('exit', (code, signal) => {
      clearTimeout(timer)
      if (code === 0 && signal === null) resolve()
      else reject(new Error(`${mode} failed (code=${code}, signal=${signal}): ${output}`))
    })
  })
}

async function main() {
  const selected = process.argv[2]
  const tests = { 'timer-microtask': timerMicrotask, 'nested-thenable': nestedThenable, 'guest-then-getter': guestThenGetter, 'explicit-undefined': explicitUndefined, 'error-properties': errorProperties, 'cleanup-pending': cleanupPending, 'sparse-array': () => childCase('sparse-array-child'), 'sparse-array-child': sparseArray, 'completion-reasons': completionReasons, 'shared-handler-error': sharedHandlerError, 'timer-close-observer': () => childCase('timer-close-observer-child'), 'timer-close-observer-child': timerCloseObserver, 'synchronous-throw-completions': synchronousThrowCompletions, 'conversion-rejects': () => childCase('conversion-rejects-child'), 'conversion-rejects-child': conversionRejects, 'conversion-observer-rejects': () => childCase('conversion-observer-rejects-child'), 'conversion-observer-rejects-child': conversionObserverRejects, 'sync-host-throw': syncHostThrow, 'argument-budget': () => childCase('argument-budget-child'), 'argument-budget-child': argumentBudget, 'call-host-failure': callHostFailure, 'constructor-failure': constructorFailure, 'worker-finalizer': workerFinalizer, 'worker-pending-natural-exit': workerPendingNaturalExit, 'pending-engine-gc': () => childCase('pending-engine-gc-child'), 'pending-engine-gc-child': pendingEngineGc }
  if (!selected) throw new Error('select one review case')
  assert.ok(tests[selected], `unknown review case: ${selected}`)
  await tests[selected]()
  console.log(`node SDK review case passed: ${selected}`)
}

main().catch(error => { console.error(error && error.stack || valueOf(error)); process.exitCode = 1 })
