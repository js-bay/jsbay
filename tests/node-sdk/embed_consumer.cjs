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
  assert.throws(() => engine.evaluate('1', 'closed.js'), error => error.status === 4 && /closed/i.test(error.message))
  const closeOnLog = addon.createCloseOnLog(702)
  assert.equal(closeOnLog.evaluate('console.log("close from log"); 9', 'embed-log-close.js'), 9)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(addon.stats().closeAttempts, 1)
  assert.throws(() => closeOnLog.evaluate('1', 'closed-after-log.js'), error => error.status === 4 && /closed/i.test(error.message))
  assert.equal(addon.stats().destroys, 2)
  assert.equal(addon.rawCloseOnLog(703), true)
  const reused = addon.create(703)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(addon.stats().destroyDuringLog, 0)
  assert.equal(addon.stats().destroys, 3)
  assert.equal(await reused.evaluateAsync('new Promise(resolve => setTimeout(() => resolve(17), 0))', 'reused.js'), 17)
  reused.close()
  await new Promise(resolve => setImmediate(resolve))
  const idle = addon.create(704)
  idle.close()
  assert.equal(addon.stats().destroys, 5)
  const replaced = addon.create(705)
  const staleValues = [replaced.value({ oldGeneration: true }), replaced.evaluateValue('43')]
  assert.equal(addon.destroyAndReplace(705), true)
  assert.throws(() => replaced.evaluate('globalThis.replacementProbe = true', 'stale.js'))
  assert.throws(() => replaced.evaluateValue('43', 'stale-value.js'))
  assert.throws(() => replaced.value({ fromOldEngine: true }))
  assert.throws(() => replaced.global())
  assert.throws(() => replaced.object())
  assert.throws(() => replaced.array())
  assert.throws(() => replaced.bind('replacementProbe', () => true))
  replaced.close()
  for (const staleValue of staleValues) {
    assert.throws(() => staleValue.type(), /status|closed|stale|instance/i)
    assert.doesNotThrow(
      () => staleValue.close(),
      'closing a replaced Engine invalidates every NodeValue'
    )
  }
  assert.equal(
    addon.replacementValueIsAlive(),
    true,
    'old-generation operations and cleanup must not affect the replacement engine'
  )
  const raced = addon.create(706)
  assert.equal(addon.raceDestroyAndReplace(706, raced.generation), true)
  assert.throws(() => raced.evaluate('40 + 2', 'raced-stale.js'))
  await raced.closeAsync()
  assert.equal(
    addon.replacementValueIsAlive(),
    true,
    'a deferred old-generation destroy must leave a concurrent replacement alive'
  )
  const cleanup = execFileSync(process.execPath, [resolve(__dirname, 'embed_cleanup_consumer.cjs')], {
    encoding: 'utf8',
    env: process.env,
  })
  assert.equal(cleanup.match(/JSBAY_NODE_EMBED_ENV_DESTROY/g)?.length, 1)
}

main().then(() => console.log('JSBAY_NODE_EMBED_PASS'))
