import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const require = createRequire(process.env.JSBAY_NODE_PACKAGE_ROOT || import.meta.url)
const addon = require('@js-bay/node')

assert.equal(typeof addon.Engine.create, 'function')
const engine = addon.Engine.create({ instanceId: 4381 })
try {
  assert.equal(engine.evaluate('6 * 7', 'package.mjs'), 42)
} finally {
  engine.close()
}

console.log('node SDK package consumer passed')
