'use strict'

const assert = require('node:assert/strict')
const { Worker } = require('node:worker_threads')

const entry = process.env.JSBAY_NODE_PUBLIC_ENTRY
assert.ok(entry, 'JSBAY_NODE_PUBLIC_ENTRY must name the Node package entry')
assert.equal(process.env.JSC_usePollingTraps, undefined, 'the parent process starts without a polling override')

function nextMessage(worker, predicate, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(new Error(`${label} timed out`)), 5000)
    const onMessage = value => {
      if (predicate(value)) finish(null, value)
    }
    const onError = error => finish(error)
    function finish(error, value) {
      clearTimeout(timer)
      worker.off('message', onMessage)
      worker.off('error', onError)
      if (error) reject(error)
      else resolve(value)
    }
    worker.on('message', onMessage)
    worker.on('error', onError)
  })
}

async function main() {
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads')
    const { Engine } = require(workerData.entry)
    const engine = Engine.create({ instanceId: 17201 })
    engine.bind('notifyEvaluation', () => parentPort.postMessage({ type: 'evaluating' }))
    parentPort.postMessage({ type: 'ready', token: engine.controlToken })
    try {
      engine.evaluate('notifyEvaluation(); while (true) {}')
      parentPort.postMessage({ type: 'result', outcome: 'completed' })
    } catch (error) {
      parentPort.postMessage({ type: 'result', outcome: 'interrupted', message: String(error.message) })
    } finally {
      engine.close()
      parentPort.postMessage({ type: 'closed' })
    }
  `, { eval: true, workerData: { entry } })

  try {
    const ready = await nextMessage(worker, message => message.type === 'ready', 'worker readiness')
    await nextMessage(worker, message => message.type === 'evaluating', 'worker evaluation start')
    const { Engine } = require(entry)
    assert.equal(process.env.JSC_usePollingTraps, 'true', 'the main entry selects polling traps before loading the addon')
    assert.equal(Engine.capabilities().executionLimit, true)
    assert.equal(Engine.requestInterrupt(ready.token), true)
    const result = await nextMessage(worker, message => message.type === 'result', 'worker interrupt')
    assert.equal(result.outcome, 'interrupted')
    await nextMessage(worker, message => message.type === 'closed', 'worker close')
  } finally {
    await worker.terminate()
  }
}

main().catch(error => {
  process.nextTick(() => { throw error })
})
