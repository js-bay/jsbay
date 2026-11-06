'use strict'

const assert = require('node:assert/strict')
const addon = require('../../sdk/node')

function engineFor(test) {
  const engine = addon.Engine.create()
  try { test(engine) } finally { engine.close() }
}

async function main() {
  const selected = process.argv[2]
  if (!selected || selected === 'm1') {
    const engine = addon.Engine.create()
    try {
      await assert.rejects(engine.evaluateAsync('new Proxy({}, { ownKeys(){ throw new Error("guest reflection failed") } })'), error => {
        assert.notEqual(error, undefined)
        assert.match(error.message, /guest reflection failed|convert/i)
        return true
      })
      engine.bindAsync('hostProxy', () => new Proxy({}, { ownKeys() { throw new Error('host reflection failed') } }))
      await assert.rejects(engine.evaluateAsync('hostProxy()'), /host reflection failed/)
      await assert.rejects(engine.evaluateAsync('throw Object.assign(new Error("bad"), { message: 42 })'), error => {
        assert.ok(error instanceof Error)
        return true
      })
      assert.equal(engine.evaluate('42'), 42)
    } finally { engine.close() }
  }
  if (!selected || selected === 'm2') engineFor(engine => {
    engine.bind('partial', () => [() => 1])
    engine.bind('identity', value => value)
    const argumentMessage = engine.evaluate("(()=>{ try { identity(new Proxy({}, { ownKeys(){ throw new Error('guest argument failed') } })) } catch (error) { return error.message } })()")
    assert.equal(argumentMessage, 'guest argument failed')
    const partialMessage = engine.evaluate("(()=>{ try { partial() } catch (error) { return error.message } })()")
    assert.notEqual(partialMessage, 'native callback returned invalid status')
    for (let index = 0; index < 64; index++) {
      assert.equal(engine.evaluate('(()=>{ try { partial() } catch { return 1 } })()'), 1)
    }
    assert.equal(engine.evaluate('42'), 42)
  })
  if (!selected || selected === 'm5') engineFor(engine => {
    addon._testFail('node_string')
    assert.throws(() => engine.evaluate("'text'"))
    assert.equal(engine.evaluate('42'), 42)
    addon._testFail('node_key')
    assert.throws(() => engine.evaluate('({ key: 1 })'))
    assert.equal(engine.evaluate('42'), 42)
  })
  if (!selected || selected === 'm6') engineFor(engine => {
    const guestDag = 'let v={x:1}; for(let i=0;i<14;i++) v=[v,v]; v'
    assert.throws(() => engine.evaluate(guestDag))
    let hostDag = { x: 1 }
    for (let index = 0; index < 14; index++) hostDag = [hostDag, hostDag]
    engine.bind('hostDag', () => hostDag)
    assert.throws(() => engine.evaluate('hostDag()'))
    engine.bind('largeBytes', () => new Uint8Array(17 * 1024 * 1024))
    assert.throws(() => engine.evaluate('largeBytes()'))
    assert.throws(() => engine.evaluate("'x'.repeat(17 * 1024 * 1024)"))
    for (const field of ['message', 'name', 'stack']) {
      engine.bind('largeError', () => {
        const error = new Error('small')
        Object.defineProperty(error, field, { value: 'x'.repeat(17 * 1024 * 1024), configurable: true })
        return error
      })
      assert.throws(() => engine.evaluate('largeError()'))
    }
    engine.bind('combinedError', () => {
      const error = new Error('small')
      error.message = 'x'.repeat(9 * 1024 * 1024)
      error.stack = 'x'.repeat(9 * 1024 * 1024)
      return error
    })
    assert.throws(() => engine.evaluate('combinedError()'))
    assert.throws(() => engine.evaluate("(()=>{ const error = new Error('x'.repeat(9 * 1024 * 1024)); error.stack = 'x'.repeat(9 * 1024 * 1024); throw error })()"))
    assert.equal(engine.evaluate('42'), 42)
  })
  if (!selected || selected === 'node-boundary') engineFor(engine => {
    const source = count => `Object.fromEntries(Array.from({length:${count}}, (_, index) => ['key' + index, index]))`
    const accepted = engine.evaluate(source(9999))
    assert.equal(Object.keys(accepted).length, 9999)
    assert.equal(accepted.key9998, 9998)
    assert.throws(() => engine.evaluate(source(10000)), /too many properties/)
    let hostValue = Object.fromEntries(Array.from({ length: 9999 }, (_, index) => ['key' + index, index]))
    engine.bind('boundary', () => hostValue)
    assert.equal(engine.evaluate('Object.keys(boundary()).length'), 9999)
    hostValue.key9999 = 9999
    assert.throws(() => engine.evaluate('boundary()'), /status 7/)
    let reads = 0
    const oversized = new Proxy(hostValue, {
      getOwnPropertyDescriptor(target, key) { reads++; return Reflect.getOwnPropertyDescriptor(target, key) }
    })
    Object.keys(oversized)
    const enumerationReads = reads
    reads = 0
    engine.bind('oversized', () => oversized)
    assert.throws(() => engine.evaluate('oversized()'), /status 7/)
    assert.ok(reads <= enumerationReads, 'oversized host conversion stops before reading each value descriptor again')
    engine.evaluate(`globalThis.descriptorReads = 0; globalThis.oversized = new Proxy(${source(10000)}, {
      getOwnPropertyDescriptor(target, key) { descriptorReads++; return Reflect.getOwnPropertyDescriptor(target, key) }
    }); Object.keys(oversized); globalThis.enumerationReads = descriptorReads; descriptorReads = 0; void 0`)
    assert.throws(() => engine.evaluate('oversized'), /too many properties/)
    assert.ok(engine.evaluate('descriptorReads <= enumerationReads'), 'oversized guest conversion stops before reading each value descriptor again')
    assert.equal(engine.evaluate('42'), 42)
  })
  console.log(`node conversion fault consumer passed${selected ? `: ${selected}` : ''}`)
}

main().catch(error => { console.error(error); process.exitCode = 1 })
