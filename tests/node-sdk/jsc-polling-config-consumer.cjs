'use strict'

const assert = require('node:assert/strict')

const entry = process.env.JSBAY_NODE_PUBLIC_ENTRY
assert.ok(entry, 'JSBAY_NODE_PUBLIC_ENTRY must name the Node package entry')
const expected = process.argv[2]
assert.ok(expected, 'an expected polling option value is required')
if (expected === 'true') {
  assert.equal(process.env.JSC_usePollingTraps, undefined, 'the package entry leaves default selection to core')
} else {
  assert.equal(process.env.JSC_usePollingTraps, expected, 'the package entry preserves an explicit setting')
}

const { Engine } = require(entry)
const enabled = ['true', 'yes', '1'].includes(expected.toLowerCase())
const invalid = !enabled && !['false', 'no', '0'].includes(expected.toLowerCase())
const capabilities = Engine.capabilities()
assert.equal(capabilities.executionLimit, enabled)
assert.equal((capabilities.flags & (1 << 2)) !== 0, enabled, 'the flags match the effective interrupt capability')

if (!invalid) {
  const engine = Engine.create()
  try {
    assert.equal(engine.evaluate('6 * 7'), 42)
    if (!enabled) {
      assert.throws(() => engine.setExecutionTimeLimit(100), { code: 'JSBAY_UNSUPPORTED' })
      assert.throws(() => engine.setExecutionBudget(100), { code: 'JSBAY_UNSUPPORTED' })
      assert.equal(engine.requestInterrupt(), false)
      assert.equal(engine.cancel(), false)
      assert.equal(engine.beginShutdown(100), false)
    }
  } finally {
    engine.close()
  }
} else {
  assert.throws(() => Engine.create(), /could not create JsBay engine/i)
}

console.log(`JSC polling configuration preserved: ${expected}`)
