'use strict'

const assert = require('node:assert/strict')
const { mkdtemp, rm } = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const { Worker } = require('node:worker_threads')

const addonPath = process.env.JSBAY_NODE_ADDON
assert.ok(addonPath, 'JSBAY_NODE_ADDON must name the Node-API module')
const { Engine } = require(addonPath)

function withTimeout(promise, label, milliseconds = 3000) {
  let timer
  const expiry = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds) })
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer))
}

function nextMessage(target, predicate, label) {
  return withTimeout(new Promise((resolve, reject) => {
    const onMessage = value => {
      if (!predicate(value)) return
      cleanup()
      resolve(value)
    }
    const onError = error => { cleanup(); reject(error) }
    const cleanup = () => {
      target.off('message', onMessage)
      target.off('error', onError)
    }
    target.on('message', onMessage)
    target.on('error', onError)
  }), label)
}

async function resourceLimitsAndUsage() {
  const engine = Engine.create({
    instanceId: 17101,
    limits: { maxTimers: 3, maxTsfnHandles: 4, maxPendingCalls: 5, maxPendingBytes: 4096, maxPendingTasks: 6 }
  })
  try {
    const initial = engine.resourceUsage()
    for (const field of ['timers', 'tsfn_handles', 'pending_calls', 'native_tasks', 'script_tasks', 'pending_bytes']) {
      assert.equal(typeof initial[field], 'bigint', `${field} is an exact unsigned resource count`)
    }
    assert.equal(initial.timers, 0n)
    assert.equal(engine.setResourceLimits({ maxTimers: 2, maxTsfnHandles: 4, maxPendingCalls: 5, maxPendingBytes: 4096, maxPendingTasks: 6 }), true)
    engine.evaluate('setTimeout(() => {}, 1000); setTimeout(() => {}, 1000)')
    assert.equal(engine.resourceUsage().timers, 2n, 'accepted guest timers are reflected in resource counts')
    assert.throws(() => engine.setResourceLimits({ maxTimers: -1 }), /limit|argument|resource/i, 'negative resource limits are rejected')
    const globalUsage = Engine.globalResourceUsage()
    assert.ok(Object.keys(globalUsage).length > 0)
    assert.ok(Object.values(globalUsage).every(value => typeof value === 'bigint'), 'process resource counters preserve integer precision')
    assert.ok(Engine.listEngines().includes(engine.id))

    const snapshot = engine.snapshot()
    assert.equal(snapshot.instanceId, engine.id)
    assert.equal(snapshot.generation, engine.generation)
    assert.equal(typeof snapshot.ownerThreadId, 'bigint')
    assert.equal(typeof snapshot.timersRegistered, 'bigint')
    assert.equal(typeof snapshot.limits.maxTimers, 'bigint')
    assert.equal(engine.setAdmissionClass('background'), true)
    assert.equal(engine.admissionClass(), 'background')
    assert.equal(engine.snapshot().admissionClass, 'background')
    assert.equal(engine.setAdmissionClass('foreground'), true)
  } finally {
    await engine.closeAsync()
  }
}

async function consoleCallbacksAndClose() {
  const logs = []
  const events = []
  const engine = Engine.create({
    instanceId: 17102,
    onLog: (...args) => logs.push(args),
    onEvent: event => events.push(event)
  })
  try {
    engine.evaluate("console.log('consumer', 42)")
    await withTimeout(new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { clearInterval(poll); reject(new Error('console callbacks timed out')) }, 3000)
      const poll = setInterval(() => {
        if (logs.some(args => args[2].includes('consumer')) && events.some(event => event.kind === 0 && event.message?.includes('consumer'))) {
          clearTimeout(timeout)
          clearInterval(poll)
          resolve()
        }
      }, 1)
    }), 'console callbacks')
    const consumerLog = logs.find(args => args[2].includes('consumer'))
    assert.ok(consumerLog)
    assert.equal(consumerLog[0], engine.id)
    assert.equal(typeof consumerLog[1], 'number')
    assert.match(consumerLog[2], /consumer.*42/)
    const logEvent = events.find(event => event.kind === 0 && event.message?.includes('consumer'))
    assert.equal(logEvent.instanceId, engine.id)
    assert.equal(typeof logEvent.status, 'number')
    assert.equal(typeof logEvent.detail, 'bigint')
    assert.equal(logEvent.message, consumerLog[2])

    await engine.closeAsync()
    const counts = [logs.length, events.length]
    await new Promise(resolve => setImmediate(resolve))
    assert.deepEqual([logs.length, events.length], counts, 'closeAsync settles only after callbacks have stopped')
  } finally {
    await engine.closeAsync()
  }
}

async function closeFromHostCallback() {
  let engine
  let closing
  let resolveClosed
  const closed = new Promise(resolve => { resolveClosed = resolve })
  engine = Engine.create({
    instanceId: 17107,
    onLog: (_instanceId, _level, message) => {
      if (message.includes('reentrant-close') && !closing) {
        closing = engine.closeAsync()
        closing.then(resolveClosed)
      }
    }
  })
  engine.evaluate("console.log('reentrant-close')")
  await withTimeout(closed, 'close from host callback')
  await closing
  assert.throws(() => engine.evaluate('1'), /closed/i, 'closeAsync called by a host callback closes the engine after that callback returns')
}

async function staleQueuedCallbackDoesNotReachReplacement() {
  const oldLogs = []
  const newLogs = []
  const oldEngine = Engine.create({ instanceId: 17108, onLog: (...args) => oldLogs.push(args) })
  oldEngine.evaluate("console.log('old-instance')")
  const oldLogsBeforeClose = oldLogs.length
  const oldClose = oldEngine.closeAsync()
  const replacement = Engine.create({ instanceId: 17108, onLog: (...args) => newLogs.push(args) })
  try {
    replacement.evaluate("console.log('new-instance')")
    await oldClose
    await withTimeout(new Promise((resolve, reject) => {
      const deadline = setTimeout(() => { clearInterval(poll); reject(new Error('replacement log timed out')) }, 3000)
      const poll = setInterval(() => {
        if (newLogs.some(args => args[2].includes('new-instance'))) {
          clearTimeout(deadline)
          clearInterval(poll)
          resolve()
        }
      }, 1)
    }), 'replacement log delivery')
    assert.equal(oldLogs.length, oldLogsBeforeClose, 'closed listeners do not receive messages after close')
    assert.ok(newLogs.every(args => args[0] === replacement.id && !args[2].includes('old-instance')))
  } finally {
    await replacement.closeAsync()
  }
}

async function callbackReplacementAndClear() {
  const firstLogs = []
  const secondLogs = []
  const firstEvents = []
  const secondEvents = []
  const engine = Engine.create({ instanceId: 17109, onLog: (...args) => firstLogs.push(args), onEvent: event => firstEvents.push(event) })
  try {
    engine.evaluate("console.log('before-replacement')")
    assert.equal(engine.setLogHandler((...args) => secondLogs.push(args)), true)
    assert.equal(engine.setEventHandler(event => secondEvents.push(event)), true)
    engine.evaluate("console.log('after-replacement')")
    await withTimeout(new Promise((resolve, reject) => {
      const deadline = setTimeout(() => { clearInterval(poll); reject(new Error('replacement callbacks timed out')) }, 3000)
      const poll = setInterval(() => {
        if (secondLogs.some(args => args[2].includes('after-replacement')) && secondEvents.some(event => event.message?.includes('after-replacement'))) {
          clearTimeout(deadline)
          clearInterval(poll)
          resolve()
        }
      }, 1)
    }), 'replacement callbacks')
    assert.equal(firstLogs.length, 0, 'queued log callbacks from the previous listener are discarded')
    assert.equal(firstEvents.length, 0, 'queued event callbacks from the previous listener are discarded')
    assert.ok(secondLogs.every(args => !args[2].includes('before-replacement')))
    assert.ok(secondEvents.every(event => !event.message?.includes('before-replacement')))
    engine.setLogHandler(null)
    engine.setEventHandler(null)
    engine.evaluate("console.log('after-clear')")
    await new Promise(resolve => setImmediate(resolve))
    assert.ok(secondLogs.every(args => !args[2].includes('after-clear')))
    assert.ok(secondEvents.every(event => !event.message?.includes('after-clear')))
  } finally {
    await engine.closeAsync()
  }
}

async function workerExitsWithListenerRegistered() {
  const worker = new Worker(`
    const { parentPort } = require('node:worker_threads')
    const { Engine } = require(process.env.JSBAY_NODE_ADDON)
    Engine.create({ onLog() {} })
    parentPort.postMessage('ready')
  `, { eval: true })
  try {
    const exited = withTimeout(new Promise((resolve, reject) => {
      worker.once('exit', resolve)
      worker.once('error', reject)
    }), 'worker exit with callback bridge')
    assert.equal(await nextMessage(worker, value => value === 'ready', 'listener worker readiness'), 'ready')
    await exited
  } finally {
    await worker.terminate()
  }
}

async function generationControlsAcrossWorker() {
  console.log('extended contract: generation control worker starting')
  const worker = new Worker(`
    const { parentPort } = require('node:worker_threads')
    const { Engine } = require(process.env.JSBAY_NODE_ADDON)
    const engine = Engine.create({ instanceId: 17103 })
    engine.bind('notifyEvaluation', () => parentPort.postMessage({ type: 'evaluating' }))
    parentPort.postMessage({ type: 'ready', token: engine.controlToken })
    try {
      engine.evaluate('notifyEvaluation(); while (true) {}')
      parentPort.postMessage({ type: 'result', outcome: 'completed' })
    } catch (error) {
      parentPort.postMessage({ type: 'result', outcome: 'interrupted', message: String(error.message) })
    } finally {
      parentPort.postMessage({ type: 'closing' })
      engine.close()
      parentPort.postMessage({ type: 'closed' })
    }
  `, { eval: true })
  try {
    const ready = await nextMessage(worker, message => message.type === 'ready', 'worker engine readiness')
    console.log('extended contract: generation control worker ready')
    await nextMessage(worker, message => message.type === 'evaluating', 'worker evaluation start')
    console.log('extended contract: worker entered evaluate')
    assert.equal(typeof ready.token.instanceId, 'number')
    assert.equal(typeof ready.token.generation, 'bigint')
    assert.ok(ready.token.generation > 0n)
    assert.equal(Engine.requestInterrupt(ready.token), true, 'a generation-scoped control can interrupt from another Worker')
    console.log('extended contract: interrupt requested')
    const result = await nextMessage(worker, message => message.type === 'result', 'worker execution interruption')
    console.log('extended contract: interrupt result received')
    assert.equal(result.outcome, 'interrupted')
    await nextMessage(worker, message => message.type === 'closing', 'worker engine close start')
    console.log('extended contract: worker engine close started')
    await nextMessage(worker, message => message.type === 'closed', 'worker engine close completion')
    console.log('extended contract: worker engine close completed')
    await worker.terminate()
    console.log('extended contract: interrupted worker terminated')

    const stale = ready.token
    const replacement = Engine.create({ instanceId: stale.instanceId })
    try {
      assert.notEqual(replacement.generation, stale.generation, 'reusing an instance id creates a distinct generation')
      assert.equal(Engine.cancel(stale), false, 'a stale token cannot cancel a replacement engine')
      assert.equal(replacement.evaluate('20 + 22'), 42, 'stale controls leave the replacement usable')
    } finally {
      await replacement.closeAsync()
      console.log('extended contract: replacement engine closed')
    }

    const cancelWorker = new Worker(`
      const { parentPort } = require('node:worker_threads')
      const { Engine } = require(process.env.JSBAY_NODE_ADDON)
      const engine = Engine.create({ instanceId: 17106 })
      parentPort.postMessage({ type: 'ready', token: engine.controlToken })
      try {
        engine.evaluate('while (true) {}')
        parentPort.postMessage({ type: 'result', outcome: 'completed' })
      } catch (error) {
        parentPort.postMessage({ type: 'result', outcome: 'cancelled', message: String(error.message) })
      } finally {
        engine.close()
      }
    `, { eval: true })
    try {
      const cancelReady = await nextMessage(cancelWorker, message => message.type === 'ready', 'cancellable worker readiness')
      console.log('extended contract: cancellable worker ready')
      assert.equal(Engine.cancel(cancelReady.token), true, 'a generation-scoped cancel can stop execution from another Worker')
      console.log('extended contract: cancel requested')
      const cancelled = await nextMessage(cancelWorker, message => message.type === 'result', 'worker cancellation')
      console.log('extended contract: cancel result received')
      assert.equal(cancelled.outcome, 'cancelled')
    } finally {
      await cancelWorker.terminate()
      console.log('extended contract: cancelled worker terminated')
    }
  } finally {
    await worker.terminate()
  }
}

async function submissionsFenceAndShutdown() {
  const engine = Engine.create({ instanceId: 17104 })
  try {
    const submissionPromise = engine.postScript('globalThis.posted = 40 + 2', 'posted.js')
    const fencePromise = engine.postFence()
    const [submission, fence] = await Promise.all([submissionPromise, fencePromise])
    assert.deepEqual(submission, { status: 'completed', error: null })
    assert.deepEqual(fence, { status: 'completed', error: null }, 'fence waits for the earlier submission checkpoint')
    assert.equal(engine.evaluate('posted'), 42)
    const failed = await engine.postScript('throw new Error("posted failure")', 'posted-error.js')
    assert.equal(failed.status, 'exception')
    assert.match(failed.error, /posted failure/)

    const token = engine.controlToken
    assert.equal(Engine.beginShutdown(token, 1000), true)
    const status = Engine.shutdownStatus(token)
    assert.equal(status.phase, 1, 'an accepted shutdown starts in the closing phase')
    assert.equal(typeof status.remainingMs, 'bigint')
    assert.ok(status.remainingMs > 0n && status.remainingMs <= 1000n)
    assert.equal(Engine.beginShutdown(token, 2000), true, 'a repeated shutdown request is accepted without resetting its deadline')
    const repeated = Engine.shutdownStatus(token)
    assert.ok(repeated.remainingMs <= status.remainingMs + 1n, 'repeated beginShutdown does not extend the grace period')
  } finally {
    await engine.closeAsync()
  }
}

async function cachePauseAndGc() {
  const cacheDir = await mkdtemp(path.join(os.tmpdir(), 'jsbay-node-cache-'))
  const engine = Engine.create({ instanceId: 17105 })
  try {
    const options = { cacheDir, cacheVersion: 'consumer-contract-v1' }
    assert.equal(engine.evaluate('6 * 7', 'cache.js', options), 42)
    assert.equal(engine.lastCacheHit(), false, 'the first cache evaluation has no prior entry')
    assert.equal(engine.evaluate('6 * 7', 'cache.js', options), 42)
    if (Engine.capabilities().bytecodeCache) {
      assert.equal(engine.lastCacheHit(), true, 'the next matching evaluation reports a cache hit')
    }

    assert.equal(engine.isSuspended(), false)
    assert.equal(engine.suspend(), true)
    assert.equal(engine.isSuspended(), true)
    engine.evaluate('globalThis.resumeCount = 0; setTimeout(() => resumeCount++, 20)')
    await new Promise(resolve => setTimeout(resolve, 40))
    assert.equal(engine.evaluate('resumeCount'), 0, 'suspend pauses guest timers')
    assert.equal(engine.resume(), true)
    assert.equal(engine.isSuspended(), false)
    await engine.evaluateAsync('new Promise(resolve => setTimeout(resolve, 30))')
    assert.equal(engine.evaluate('resumeCount'), 1, 'resume delivers the overdue timer once')
    assert.doesNotThrow(() => engine.runGc())
  } finally {
    await engine.closeAsync()
    await rm(cacheDir, { recursive: true, force: true })
  }
}

function proxyClosingOnOwnKeys(close) {
  return new Proxy({}, {
    getPrototypeOf() { return Object.prototype },
    ownKeys() {
      close()
      return []
    },
    getOwnPropertyDescriptor() { return undefined }
  })
}

async function valueReceiverAndReentrantConversionSafety() {
  const receiverEngine = Engine.create({ instanceId: 17108 })
  const nodeValue = receiverEngine.object()
  const value = receiverEngine.object()
  try {
    assert.throws(() => receiverEngine.evaluate.call(nodeValue, '1'), Error, 'Engine methods reject a NodeValue receiver')
    assert.throws(() => value.get.call(receiverEngine, 'x'), Error, 'Value methods reject an Engine receiver')
    assert.equal(receiverEngine.evaluate('6 * 7'), 42, 'receiver validation leaves the engine usable')
  } finally {
    nodeValue.close()
    value.close()
    await receiverEngine.closeAsync()
  }

  const setEngine = Engine.create({ instanceId: 17109 })
  const setTarget = setEngine.object()
  const closingEngineProxy = proxyClosingOnOwnKeys(() => setEngine.close())
  try {
    assert.throws(() => setTarget.set('trigger', closingEngineProxy), Error, 'set rejects conversion after its Engine closes reentrantly')
  } finally {
    await setEngine.closeAsync()
  }

  const setValueEngine = Engine.create({ instanceId: 17110 })
  const closingTarget = setValueEngine.object()
  const closingTargetProxy = proxyClosingOnOwnKeys(() => closingTarget.close())
  try {
    assert.throws(() => closingTarget.set('trigger', closingTargetProxy), Error, 'set rejects a receiver closed during host-value conversion')
    assert.equal(setValueEngine.evaluate('40 + 2'), 42, 'closing one Value during conversion does not close its Engine')
  } finally {
    closingTarget.close()
    await setValueEngine.closeAsync()
  }

  const callEngine = Engine.create({ instanceId: 17111 })
  const objectConstructor = callEngine.global().get('Object')
  const callClosingEngineProxy = proxyClosingOnOwnKeys(() => callEngine.close())
  try {
    assert.throws(() => objectConstructor.call(undefined, callClosingEngineProxy), Error, 'call rejects conversion after its Engine closes reentrantly')
  } finally {
    await callEngine.closeAsync()
  }

  const callValueEngine = Engine.create({ instanceId: 17112 })
  const callTarget = callValueEngine.global().get('Object')
  const closedArgument = callValueEngine.value(7)
  const closingArgumentProxy = proxyClosingOnOwnKeys(() => closedArgument.close())
  try {
    assert.throws(
      () => callTarget.call(undefined, closingArgumentProxy, closedArgument),
      Error,
      'call rejects a NodeValue argument closed by an earlier Proxy conversion trap'
    )
    assert.equal(callValueEngine.evaluate('40 + 2'), 42, 'a closed argument does not invalidate the Engine')
  } finally {
    callTarget.close()
    closedArgument.close()
    await callValueEngine.closeAsync()
  }
}

async function runPhase(name, action) {
  console.log(`extended contract: ${name} starting`)
  await action()
  console.log(`extended contract: ${name} passed`)
}

async function main() {
  await runPhase('resource limits and usage', resourceLimitsAndUsage)
  await runPhase('console callbacks and close', consoleCallbacksAndClose)
  await runPhase('stale callback replacement', staleQueuedCallbackDoesNotReachReplacement)
  await runPhase('callback replacement and clear', callbackReplacementAndClear)
  await runPhase('worker exit with listener', workerExitsWithListenerRegistered)
  await runPhase('close from host callback', closeFromHostCallback)
  await runPhase('close from host callback repeat', closeFromHostCallback)
  await runPhase('generation controls across Worker', generationControlsAcrossWorker)
  await runPhase('submission fence and shutdown', submissionsFenceAndShutdown)
  await runPhase('cache pause and GC', cachePauseAndGc)
  await runPhase('value receiver and reentrant conversion', valueReceiverAndReentrantConversionSafety)
}

main().catch(error => {
  process.nextTick(() => { throw error })
})
