'use strict'

const { Worker, isMainThread, parentPort, workerData } = require('worker_threads')
const native = require(process.env.JSBAY_HARMONY_NODE)

function expect(value, message) {
  if (!value) throw new Error(message)
}

function release(value) {
  if (value) native.release(value)
}

if (!isMainThread) {
  const bridge = require(workerData.addon)
  parentPort.postMessage(bridge.cancelEngine(workerData.id, BigInt(workerData.generation)))
  return
}

function evaluateNumber(engine, source, message) {
  const value = native.evaluate(engine, source, 'remediation.js')
  try { expect(native.toNumber(value) === 42, message) } finally { release(value) }
}

async function cancelFromWorker(id, generation) {
  return await new Promise((resolve, reject) => {
    const worker = new Worker(__filename, { workerData: { addon: process.env.JSBAY_HARMONY_NODE, id, generation: generation.toString() } })
    worker.once('message', resolve)
    worker.once('error', reject)
  })
}

async function main() {
  const id = 17701
  const engine = native.create(id)
  let retiredGeneration
  try {
    const dropped = []
    for (let index = 0; index < 20000; index += 1) dropped.push(native.newObject(engine))
    expect(native.getValueUsage(engine).live >= 20000n, 'owned value accounting missed live wrappers')
    dropped.length = 0
    if (global.gc) { global.gc(); global.gc() }
    await new Promise(resolve => setImmediate(resolve))
    if (global.gc) { global.gc(); global.gc() }
    expect(native.getValueUsage(engine).abandoned > 0n, 'GC did not record abandoned owned wrappers')
    expect(native.setExecutionBudget(engine, 20n), 'budget configured')
    await new Promise(resolve => setTimeout(resolve, 60))
    evaluateNumber(engine, '6 * 7', 'idle time consumed the per-entry budget')
    let budgetInterrupted = false
    try { native.evaluate(engine, 'for (;;) {}', 'budget-loop.js') } catch (_) { budgetInterrupted = true }
    expect(budgetInterrupted, 'budget did not interrupt an infinite evaluation')
    evaluateNumber(engine, '6 * 7', 'budget interruption did not recover')
    expect(native.setExecutionBudget(engine, 0n), 'budget disabled before cancellation test')

    const snapshot = native.snapshotEngine(id)
    expect(snapshot && typeof snapshot.generation === 'bigint', 'missing generation snapshot')
    retiredGeneration = snapshot.generation
    expect(await cancelFromWorker(id, snapshot.generation), 'cross-thread cancel was rejected')
    expect(native.clearInterrupt(engine), 'clearInterrupt rejected')
    let shutdownInterrupted = false
    try { native.evaluate(engine, 'for (;;) {}', 'shutdown.js') } catch (_) { shutdownInterrupted = true }
    expect(shutdownInterrupted, 'clearInterrupt cleared lifecycle cancellation')
  } finally {
    native.close(engine)
  }

  const replacement = native.create(id)
  try {
    const usage = native.getValueUsage(replacement)
    expect(usage.live === 0n && usage.peak === 0n && usage.abandoned === 0n, 'close did not reset value diagnostics for replacement')
    expect(!native.cancelEngine(id, retiredGeneration), 'stale generation cancelled a replacement')
    evaluateNumber(replacement, '6 * 7', 'replacement did not run')
  } finally {
    native.close(replacement)
  }
  console.log('REMEDIATION_CONSUMER=pass')
}

main().catch(error => {
  console.error(error && error.stack || String(error))
  process.exitCode = 1
})
