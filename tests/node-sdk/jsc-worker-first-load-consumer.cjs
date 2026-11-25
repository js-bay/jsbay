'use strict'

const assert = require('node:assert/strict')
const { Worker } = require('node:worker_threads')

const entry = process.env.JSBAY_NODE_PUBLIC_ENTRY
assert.ok(entry, 'JSBAY_NODE_PUBLIC_ENTRY must name the Node package entry')
assert.equal(process.env.JSC_usePollingTraps, undefined, 'the parent process starts without a polling override')

function createInbox(worker) {
  const messages = []
  const waiters = []
  worker.on('message', message => {
    const index = waiters.findIndex(waiter => waiter.predicate(message))
    if (index < 0) {
      messages.push(message)
      return
    }
    const [waiter] = waiters.splice(index, 1)
    clearTimeout(waiter.timer)
    waiter.resolve(message)
  })
  worker.on('error', error => {
    for (const waiter of waiters.splice(0)) {
      clearTimeout(waiter.timer)
      waiter.reject(error)
    }
  })
  return (predicate, label) => {
    const index = messages.findIndex(predicate)
    if (index >= 0) return Promise.resolve(messages.splice(index, 1)[0])
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, reject }
      waiter.timer = setTimeout(() => {
        const waiterIndex = waiters.indexOf(waiter)
        if (waiterIndex >= 0) waiters.splice(waiterIndex, 1)
        reject(new Error(`${label} timed out`))
      }, 5000)
      waiters.push(waiter)
    })
  }
}

async function main() {
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads')
    const { Engine } = require(workerData.entry)
    function runDeadline(name, configure) {
      const engine = Engine.create()
      configure(engine)
      try {
        engine.evaluate('while (true) {}')
        parentPort.postMessage({ type: 'result', name, outcome: 'completed' })
      } catch (error) {
        parentPort.postMessage({ type: 'result', name, outcome: 'threw', message: String(error.message) })
      } finally {
        engine.close()
        parentPort.postMessage({ type: 'closed', name })
      }
    }
    function runControlled(name) {
      const engine = Engine.create()
      engine.bind('notifyEvaluation', () => parentPort.postMessage({ type: 'evaluating', name }))
      parentPort.postMessage({ type: 'ready', name, token: engine.controlToken })
      try {
        engine.evaluate('notifyEvaluation(); while (true) {}')
        parentPort.postMessage({ type: 'result', name, outcome: 'completed' })
      } catch (error) {
        parentPort.postMessage({ type: 'result', name, outcome: 'threw', message: String(error.message) })
      } finally {
        engine.close()
        parentPort.postMessage({ type: 'closed', name })
      }
    }
    runDeadline('execution-limit', engine => engine.setExecutionTimeLimit(100))
    runDeadline('execution-budget', engine => engine.setExecutionBudget(100))
    runControlled('interrupt')
    runControlled('shutdown-deadline')
  `, { eval: true, workerData: { entry } })

  try {
    const nextMessage = createInbox(worker)
    for (const name of ['execution-limit', 'execution-budget']) {
      const result = await nextMessage(message => message.type === 'result' && message.name === name, `${name} result`)
      assert.equal(result.outcome, 'threw', `${name} must terminate the infinite script`)
      assert.ok(result.message, `${name} must report the interrupted evaluation`)
      await nextMessage(message => message.type === 'closed' && message.name === name, `${name} close`)
    }

    const interruptReady = await nextMessage(message => message.type === 'ready' && message.name === 'interrupt', 'interrupt worker readiness')
    await nextMessage(message => message.type === 'evaluating' && message.name === 'interrupt', 'interrupt evaluation start')
    const { Engine } = require(entry)
    assert.equal(process.env.JSC_usePollingTraps, 'true', 'the main entry selects polling traps before loading the addon')
    assert.equal(Engine.capabilities().executionLimit, true)
    assert.equal(Engine.requestInterrupt(interruptReady.token), true)
    const interruptResult = await nextMessage(message => message.type === 'result' && message.name === 'interrupt', 'worker interrupt')
    assert.equal(interruptResult.outcome, 'threw')
    await nextMessage(message => message.type === 'closed' && message.name === 'interrupt', 'interrupt worker close')

    const shutdownReady = await nextMessage(message => message.type === 'ready' && message.name === 'shutdown-deadline', 'shutdown worker readiness')
    await nextMessage(message => message.type === 'evaluating' && message.name === 'shutdown-deadline', 'shutdown evaluation start')
    assert.equal(Engine.beginShutdown(shutdownReady.token, 100), true)
    const shutdownResult = await nextMessage(message => message.type === 'result' && message.name === 'shutdown-deadline', 'shutdown deadline result')
    assert.equal(shutdownResult.outcome, 'threw')
    await nextMessage(message => message.type === 'closed' && message.name === 'shutdown-deadline', 'shutdown worker close')
  } finally {
    await worker.terminate()
  }
}

main().catch(error => {
  process.nextTick(() => { throw error })
})
