'use strict'
const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const addon = require('../../sdk/node')
async function flush() { for (let index = 0; index < 3; index++) { global.gc(); await new Promise(resolve => setImmediate(resolve)) } }

async function runHandlerChild(point, outcome) {
  const child = spawn(process.execPath, ['--unhandled-rejections=strict', __filename, 'handler-child', point, outcome], { env: { ...process.env }, stdio: 'inherit' })
  const result = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`handler child timed out: ${point}/${outcome}`)) }, 2000)
    child.once('error', error => { clearTimeout(timeout); reject(error) })
    child.once('exit', (code, signal) => { clearTimeout(timeout); resolve({ code, signal }) })
  })
  assert.deepEqual(result, { code: 0, signal: null }, `handler child exits cleanly: ${point}/${outcome}`)
}

async function runHandlerChildCase(point, outcome) {
  const engine = addon.Engine.create()
  try {
    engine.bindAsync('value', () => {
      if (outcome === 'resolve') return Promise.resolve(42)
      if (outcome === 'reject') return Promise.reject(new Error('host operation failed'))
      return { then() { throw new Error('thenable failed') } }
    })
    addon._testFail(point)
    await assert.rejects(engine.evaluateAsync('value()'), /completion handler/)
    await new Promise(resolve => setImmediate(resolve))
  } finally { engine.close() }
}

async function main() {
  const selected = process.argv[2]
  if (!selected || selected === 'close-pending') {
    const engine = addon.Engine.create()
    let timer
    try {
      const pending = engine.evaluateAsync('new Promise(() => {})')
      void pending.catch(() => {})
      addon._testFail('close_pending')
      assert.throws(() => engine.close(), /pending error during close/)
      const expiry = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('close left evaluation pending')), 300) })
      await Promise.race([assert.rejects(pending, /closed/), expiry])
    } finally { clearTimeout(timer); engine.close() }
  }
  if (selected === 'handler-child') {
    await runHandlerChildCase(process.argv[3], process.argv[4])
    return
  }
  if (!selected || selected === 'handler-subprocesses') {
    for (const point of ['create_first', 'finalize_first', 'create_second', 'finalize_second']) {
      for (const outcome of ['resolve', 'reject', 'thenable']) await runHandlerChild(point, outcome)
    }
  }
  if (!selected || selected === 'handlers') {
    const engine = addon.Engine.create()
    engine.bindAsync('value', () => 42)
    for (const point of ['create_first', 'finalize_first', 'create_second', 'finalize_second']) {
      const before = addon._testState()
      addon._testFail(point)
      await assert.rejects(engine.evaluateAsync('value()'))
      await flush()
      const after = addon._testState()
      assert.equal(after.pendingCalls, before.pendingCalls, `${point} releases the native request`)
      assert.equal(after.completions, before.completions, `${point} releases completion metadata`)
      assert.equal(await engine.evaluateAsync('value()'), 42)
      await flush()
    }
    engine.close()
  }
  if (!selected || selected === 'completion-values') {
    const engine = addon.Engine.create()
    engine.bindAsync('value', () => 42)
    let timer
    try {
      const before = addon._testState()
      addon._testFail('create_first,completion_error')
      const expiry = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('completion remained pending')), 500) })
      await assert.rejects(Promise.race([engine.evaluateAsync('value()'), expiry]), /completion handler/)
      clearTimeout(timer)
      await flush()
      assert.equal(addon._testState().pendingCalls, before.pendingCalls)
    } finally { clearTimeout(timer); engine.close() }
  }
  if (!selected || selected === 'arguments') {
    const engine = addon.Engine.create()
    try {
      let called = 0
      engine.bind('accept', () => { called++; return 42 })
      assert.equal(engine.evaluate("(()=>{try { accept(()=>0) } catch(error) { return 'caught' }})()"), 'caught')
      assert.equal(called, 0)
      engine.bind('reflect', () => new Proxy({}, { ownKeys() { throw new Error('reflection failed') } }))
      assert.equal(engine.evaluate("(()=>{try { reflect() } catch(error) { return error.message }})()"), 'reflection failed')
      assert.equal(engine.evaluate('42'), 42)
    } finally { engine.close() }
  }
  if (!selected || selected === 'wrap') {
    await flush()
    const before = addon._testState()
    addon._testFail('wrap')
    assert.throws(() => addon.Engine.create())
    await flush()
    assert.deepEqual(addon._testState(), before, 'failed wrapper creation releases its native resources')
  }
  if (!selected || selected === 'accessors') {
    const engine = addon.Engine.create()
    try {
      let reads = 0
      for (const field of ['message', 'name', 'stack']) {
        engine.bind('value', () => { const error = new Error('value'); Object.defineProperty(error, field, { get() { reads++; return 'getter' } }); return error })
        assert.throws(() => engine.evaluate('value()'))
        assert.equal(reads, 0, `Error ${field} accessor must not execute while copying`)
        assert.throws(() => engine.evaluate(`(()=>{ const error = new Error('value'); Object.defineProperty(error, ${JSON.stringify(field)}, { get() { globalThis.guestGetterCalls++; return 'getter' } }); return error })()`))
        assert.equal(engine.evaluate('globalThis.guestGetterCalls || 0'), 0)
      }
      assert.equal(engine.evaluate('42'), 42)
    } finally { engine.close() }
  }
  if (!selected || selected === 'properties') {
    const engine = addon.Engine.create()
    try {
      engine.bind('value', () => Object.defineProperty({}, '__proto__', { value: { marker: 1 }, enumerable: true }))
      assert.equal(engine.evaluate('Object.prototype.hasOwnProperty.call(value(), "__proto__")'), true)
      engine.bind('ordinary', () => ({ guarded: 42 }))
      engine.evaluate('globalThis.setterCalls=0; Object.defineProperty(Object.prototype,"guarded",{set(){setterCalls++},configurable:true}); void 0')
      assert.equal(engine.evaluate('ordinary().guarded'), 42)
      assert.equal(engine.evaluate('setterCalls'), 0)
    } finally { engine.close() }
  }
  console.log('node SDK fault consumer passed')
}
main().catch(error => { console.error(error); process.exitCode = 1 })
