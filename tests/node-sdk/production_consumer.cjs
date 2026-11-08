'use strict'

const assert = require('node:assert/strict')

const addonPath = process.env.JSBAY_NODE_ADDON
assert.ok(addonPath, 'JSBAY_NODE_ADDON must name the production Node-API module')
const addon = require(addonPath)

assert.deepEqual(Reflect.ownKeys(addon), ['Engine'])
assert.deepEqual(Reflect.ownKeys(addon.Engine), ['create'])
console.log('production node SDK consumer passed')
