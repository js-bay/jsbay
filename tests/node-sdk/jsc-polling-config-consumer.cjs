'use strict'

const assert = require('node:assert/strict')

const entry = process.env.JSBAY_NODE_PUBLIC_ENTRY
assert.ok(entry, 'JSBAY_NODE_PUBLIC_ENTRY must name the Node package entry')
const expected = process.argv[2]
assert.ok(expected, 'an expected polling option value is required')

const { Engine } = require(entry)
assert.equal(process.env.JSC_usePollingTraps, expected, 'the package preserves or supplies the selected value')

const enabled = ['true', 'yes', '1'].includes(expected.toLowerCase())
const capabilities = Engine.capabilities()
assert.equal(capabilities.executionLimit, enabled)
assert.equal((capabilities.flags & (1 << 2)) !== 0, enabled, 'the flags match the effective interrupt capability')

if (enabled) {
  const engine = Engine.create()
  try {
    assert.equal(engine.evaluate('6 * 7'), 42)
  } finally {
    engine.close()
  }
} else {
  assert.throws(() => Engine.create(), /JSC_usePollingTraps=true/i)
}

console.log(`JSC polling configuration preserved: ${expected}`)
