'use strict'

const assert = require('node:assert/strict')
const addon = require('../../sdk/node')

async function main() {
  const engine = addon.Engine.create({ instanceId: 4111 })
  try {
    assert.equal(engine.evaluate('1 + 2', 'number.js'), 3)
    assert.deepEqual(engine.evaluate('({ name: "ok", list: [1, true, null] })', 'object.js'), { name: 'ok', list: [1, true, null] })
    assert.deepEqual(engine.evaluate('({ nested: [undefined, { value: 3 }] })', 'nested.js'), { nested: [undefined, { value: 3 }] })
    const binary = engine.evaluate('new Uint8Array([3, 4, 5])', 'binary.js')
    assert.deepEqual([...new Uint8Array(binary)], [3, 4, 5])
    engine.bind('copyView', () => new DataView(Uint8Array.from([1, 7, 9]).buffer, 1, 2))
    assert.deepEqual([...new Uint8Array(engine.evaluate('copyView()'))], [7, 9])
    engine.bind('copyNumber', value => value)
    assert.ok(Number.isNaN(engine.evaluate('copyNumber(NaN)')))
    assert.equal(engine.evaluate('copyNumber(Infinity)'), Infinity)
    assert.ok(Object.is(engine.evaluate('copyNumber(-0)'), -0))
    engine.bind('sum', (a, b) => a + b)
    assert.equal(engine.evaluate('sum(19, 23)', 'bind.js'), 42)
    engine.bindAsync('immediate', value => ({ value, ok: true }))
    assert.deepEqual(await engine.evaluateAsync('immediate(7)', 'async-value.js'), { value: 7, ok: true })
    engine.bindAsync('later', value => new Promise(resolve => setTimeout(() => resolve(value + 1), 1)))
    assert.equal(await engine.evaluateAsync('later(41)', 'async-promise.js'), 42)
    engine.bindAsync('failed', () => Promise.reject(new Error('expected rejection')))
    await assert.rejects(engine.evaluateAsync('failed()', 'async-reject.js'), /expected rejection/)
    engine.bind('copy', value => ({ value, nested: [undefined, new Uint8Array([8, 9])] }))
    const copied = engine.evaluate('copy(5)', 'copy.js')
    assert.equal(copied.value, 5)
    assert.deepEqual(copied.nested.slice(0, 1), [undefined])
    assert.deepEqual([...new Uint8Array(copied.nested[1])], [8, 9])
    engine.bind('circular', () => { const value = {}; value.self = value; return value })
    assert.throws(() => engine.evaluate('circular()', 'circular.js'))
    engine.bind('unsupported', () => () => 1)
    assert.throws(() => engine.evaluate('unsupported()', 'unsupported.js'))
    engine.bindAsync('pending', () => new Promise(resolve => setTimeout(() => resolve(1), 20)))
    const pending = engine.evaluateAsync('pending()', 'pending-close.js')
    engine.close()
    await assert.rejects(pending, /closed/)
  } finally {
    engine.close()
  }
  assert.throws(() => engine.evaluate('1', 'closed.js'))
  const first = addon.Engine.create()
  const second = addon.Engine.create()
  try {
    assert.equal(first.evaluate('6 * 7'), 42)
    first.close()
    assert.equal(second.evaluate('20 + 22'), 42)
  } finally {
    first.close()
    second.close()
  }
  const duplicate = addon.Engine.create({ instanceId: 8137 })
  try {
    assert.throws(() => addon.Engine.create({ instanceId: 8137 }))
    assert.equal(duplicate.evaluate('40 + 2'), 42)
  } finally {
    duplicate.close()
  }
  console.log('node SDK consumer passed')
}

main().catch(error => {
  console.error(error)
  process.exitCode = 1
})
