'use strict'

const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const { Worker } = require('node:worker_threads')

const addonPath = process.env.JSBAY_NODE_ADDON
assert.ok(addonPath, 'JSBAY_NODE_ADDON must name the Node-API module')
const addon = require(addonPath)

function valueOf(error) { return error instanceof Error ? error.message : error }

function deadline(promise, label, milliseconds = 1500) {
  let timer
  const expiry = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds) })
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer))
}

function child(mode) {
  return new Promise((resolve, reject) => {
    const childProcess = spawn(global.process.execPath, ['--expose-gc', __filename, mode], { env: global.process.env, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    childProcess.stdout.on('data', chunk => { output += chunk })
    childProcess.stderr.on('data', chunk => { output += chunk })
    const timer = setTimeout(() => { childProcess.kill('SIGKILL'); reject(new Error(`${mode} timed out: ${output}`)) }, 2000)
    childProcess.once('error', error => { clearTimeout(timer); reject(error) })
    childProcess.once('exit', (code, signal) => {
      clearTimeout(timer)
      if (code === 0 && signal === null) resolve(output)
      else reject(new Error(`${mode} failed (code=${code}, signal=${signal}): ${output}`))
    })
  })
}

function workerWithPending(mode) {
  return new Promise((resolve, reject) => {
    const instance = new Worker(`
      const { parentPort } = require('node:worker_threads')
      const { Engine } = require(process.env.JSBAY_NODE_ADDON)
      const engine = Engine.create({ instanceId: ${mode === 'terminate' ? '9022' : '9021'} })
      engine.bindAsync('pending', () => new Promise(() => {}))
      void engine.evaluateAsync('pending()', 'worker-pending.js')
      if (${JSON.stringify(mode)} === 'terminate') {
        parentPort.postMessage('ready')
        setInterval(() => {}, 1000)
      }
    `, { eval: true })
    const timer = setTimeout(() => { void instance.terminate(); reject(new Error(`worker ${mode} timed out`)) }, 2000)
    instance.once('error', error => { clearTimeout(timer); reject(error) })
    if (mode === 'natural') {
      instance.once('exit', code => { clearTimeout(timer); code === 0 ? resolve() : reject(new Error(`worker exited with ${code}`)) })
      return
    }
    instance.once('message', async message => {
      try {
        assert.equal(message, 'ready')
        const code = await instance.terminate()
        clearTimeout(timer)
        assert.equal(typeof code, 'number')
        resolve()
      } catch (error) {
        clearTimeout(timer)
        reject(error)
      }
    })
    instance.once('exit', () => {})
  })
}

async function rejected(promise, expected, label) {
  await assert.rejects(promise, error => { assert.equal(valueOf(error), expected, label); return true })
}

async function main() {
  assert.equal(typeof global.gc, 'function', 'run this consumer with node --expose-gc')
  const engine = addon.Engine.create({ instanceId: 9011 })
  try {
    assert.equal(engine.evaluate('6 * 7', 'sync.js'), 42)
    const asyncValue = engine.evaluateAsync('Promise.resolve(40 + 2)', 'async.js')
    assert.equal(typeof asyncValue.then, 'function', 'evaluateAsync returns a Node Promise')
    assert.equal(await asyncValue, 42)
    engine.bind('sum', (left, right) => left + right)
    assert.equal(engine.evaluate('sum(20, 22)', 'bind.js'), 42)
    engine.bindAsync('immediate', value => ({ value, nested: [undefined, { ok: true }] }))
    assert.deepEqual(await engine.evaluateAsync('immediate(7)', 'async-value.js'), { value: 7, nested: [undefined, { ok: true }] })
    engine.bindAsync('promise', value => Promise.resolve(value + 1))
    assert.equal(await engine.evaluateAsync('promise(41)', 'async-promise.js'), 42)

    const copied = engine.evaluate('({ nested: { missing: undefined, binary: new Uint8Array([0, 7, 255]), buffer: new Uint8Array([8, 9]).buffer }, list: [, undefined, , 4] })', 'values.js')
    assert.equal(Object.hasOwn(copied.nested, 'missing'), true, 'nested undefined keeps its key')
    assert.equal(copied.nested.missing, undefined)
    assert.deepEqual([...new Uint8Array(copied.nested.binary)], [0, 7, 255], 'nested typed array bytes are preserved')
    assert.deepEqual([...new Uint8Array(copied.nested.buffer)], [8, 9], 'nested ArrayBuffer bytes are preserved')
    assert.equal(copied.list.length, 4, 'sparse array length is preserved')
    assert.equal(0 in copied.list, false, 'leading array hole is preserved')
    assert.equal(1 in copied.list, true, 'undefined array element is not a hole')
    assert.equal(2 in copied.list, false, 'middle array hole is preserved')
    assert.equal(copied.list[3], 4, 'sparse array tail is preserved')
    assert.deepEqual(engine.evaluate('(()=>{ const value = { visible: 1 }; Object.defineProperty(value, "hidden", { value: 2 }); return value })()', 'hidden.js'), { visible: 1 }, 'only own enumerable object properties are copied')
    assert.throws(() => engine.evaluate('Object.create({ inherited: 1 })', 'inherited.js'), 'non-plain object is rejected')
    assert.throws(() => engine.evaluate('(()=>{ const value = {}; value.self = value; return value })()', 'cycle.js'), 'circular values are rejected')
    assert.throws(() => engine.evaluate('1n', 'bigint.js'), 'unsupported values are rejected')
    assert.throws(() => engine.evaluate('throw "guest primitive"', 'throw-primitive.js'), error => { assert.equal(valueOf(error), 'guest primitive'); return true })
    engine.bindAsync('rejectMessage', () => Promise.reject(new Error('async guest message')))
    await rejected(engine.evaluateAsync('rejectMessage()', 'reject-message.js'), 'async guest message', 'async message survives')
    engine.bindAsync('rejectPrimitive', () => Promise.reject('async primitive'))
    await rejected(engine.evaluateAsync('rejectPrimitive()', 'reject-primitive.js'), 'async primitive', 'async primitive survives')
  } finally {
    engine.close()
    engine.close()
  }
  assert.throws(() => engine.evaluate('1', 'after-close.js'), 'closed engine cannot evaluate')

  const first = addon.Engine.create()
  const second = addon.Engine.create()
  try {
    first.evaluate('globalThis.local = 20', 'first.js')
    second.evaluate('globalThis.local = 40', 'second.js')
    assert.equal(first.evaluate('local + 2', 'first-result.js'), 22)
    assert.equal(second.evaluate('local + 2', 'second-result.js'), 42)
  } finally { first.close(); second.close() }
  const named = addon.Engine.create({ instanceId: 9012 })
  try {
    assert.throws(() => addon.Engine.create({ instanceId: 9012 }), 'duplicate ID is rejected')
    assert.equal(named.evaluate('40 + 2', 'duplicate-survival.js'), 42, 'duplicate failure preserves the old engine')
  } finally { named.close() }

  for (let index = 0; index < 100; index++) {
    const transient = addon.Engine.create()
    assert.equal(transient.evaluate('1', 'repeat.js'), 1)
    transient.close()
  }
  global.gc()
  await workerWithPending('natural')
  await workerWithPending('terminate')
  await child('idle')
  const timerOutput = await child('timer')
  assert.match(timerOutput, /timer-fired/, 'guest timer invokes its host callback before child exit')
  await child('gc-finalizers')
  await child('thenable')
  await child('patched-promise')
  await child('late-completion')
  console.log('independent node SDK consumer passed')
}

async function childMain(mode) {
  const { Engine } = require(addonPath)
  if (mode === 'idle') { Engine.create({ instanceId: 9022 }); return }
  if (mode === 'timer') {
    const engine = Engine.create({ instanceId: 9023 })
    engine.bind('finish', () => { console.log('timer-fired'); engine.close() })
    engine.evaluate('setTimeout(finish, 1)', 'timer.js')
    return
  }
  if (mode === 'gc-finalizers') {
    for (let index = 0; index < 100; index++) Engine.create().evaluate('1', 'gc-finalizer.js')
    assert.equal(typeof global.gc, 'function', 'child must receive --expose-gc')
    global.gc()
    global.gc()
    return
  }
  let engine = Engine.create({ instanceId: 9024 })
  try {
    if (mode === 'thenable') {
      let calls = 0
      engine.bindAsync('value', () => ({ then(resolve, reject) { calls++; resolve(42); reject('late'); resolve(99) } }))
      assert.equal(await deadline(engine.evaluateAsync('value()', 'thenable.js'), 'thenable'), 42)
      assert.equal(calls, 1, 'thenable callback runs once')
      return
    }
    if (mode === 'patched-promise') {
      engine.bindAsync('value', () => { const promise = Promise.resolve(42); promise.then = (ok, bad) => { ok(42); bad('late'); return promise }; return promise })
      assert.equal(await deadline(engine.evaluateAsync('value()', 'patched-promise.js'), 'patched promise'), 42)
      return
    }
    if (mode === 'late-completion') {
      assert.equal(typeof global.gc, 'function', 'child must receive --expose-gc')
      let complete
      engine.bindAsync('value', () => new Promise(resolve => { complete = resolve }))
      const pending = engine.evaluateAsync('value()', 'late-completion.js')
      engine.close()
      engine = null
      await assert.rejects(deadline(pending, 'close rejection'), /closed/i)
      global.gc()
      complete(42)
      await new Promise(resolve => setImmediate(resolve))
      return
    }
    throw new Error(`unknown child mode: ${mode}`)
  } finally { engine?.close() }
}

if (process.argv[2]) childMain(process.argv[2]).catch(error => { console.error(error); process.exitCode = 1 })
else main().catch(error => { console.error(error); process.exitCode = 1 })
