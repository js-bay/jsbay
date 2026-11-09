const assert = require('node:assert/strict')
const { execFileSync } = require('node:child_process')
const { resolve } = require('node:path')

const addon = require(process.env.JSBAY_NODE_EMBED_ADDON)

async function main() {
  const engine = addon.create(701)
  assert.equal(addon.tryDuplicate(701), false)
  assert.equal(addon.stats().destroys, 0)
  engine.bindAsync('value', async () => 42)
  assert.equal(await engine.evaluateAsync('value()', 'embed-async.js'), 42)
  assert.equal(await engine.evaluateAsync('console.info("embedded"); Promise.resolve(7)', 'embed-log.js'), 7)
  engine.bind('closeFromHost', () => engine.close())
  assert.equal(engine.evaluate('closeFromHost()', 'embed-close.js'), undefined)
  await new Promise(resolve => setImmediate(resolve))
  const stats = addon.stats()
  assert.equal(stats.destroys, 1)
  assert.ok(stats.logs >= 1)
  assert.equal(stats.taskEnters, stats.taskLeaves)
  assert.throws(() => engine.evaluate('1', 'closed.js'), /status 4/)
  const closeOnLog = addon.createCloseOnLog(702)
  assert.equal(closeOnLog.evaluate('console.log("close from log"); 9', 'embed-log-close.js'), 9)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(addon.stats().closeAttempts, 1)
  assert.throws(() => closeOnLog.evaluate('1', 'closed-after-log.js'), /status 4/)
  assert.equal(addon.stats().destroys, 2)
  const cleanup = execFileSync(process.execPath, [resolve(__dirname, 'embed_cleanup_consumer.cjs')], {
    encoding: 'utf8',
    env: process.env,
  })
  assert.equal(cleanup.match(/JSBAY_NODE_EMBED_ENV_DESTROY/g)?.length, 1)
}

main().then(() => console.log('JSBAY_NODE_EMBED_PASS'))
