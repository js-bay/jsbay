'use strict'

const assert = require('node:assert/strict')
const native = require(process.env.JSBAY_HARMONY_NODE)

for (let index = 0; index < 32; index += 1) {
  const before = native.cleanupFailureAbortCount()
  assert.throws(() => native.create(47000 + index), (error) => error.status === 2)
  assert.equal(native.cleanupFailureHookCount(), index + 1,
    'construction must reach the injected cleanup-hook registration failure')
  assert.equal(native.cleanupFailureAbortCount(), before + 1,
    'failed Engine construction must abort its submission dispatcher before returning')
  assert.deepEqual(native.listEngines(), [], 'failed construction must release the core instance')
}
console.log('PASS: cleanup-hook registration failure releases every submission dispatcher')
