'use strict'

/* Exercises the production Harmony N-API bridge on Node's N-API host. Node replaces only the platform runtime; Engine, Value, loop, cleanup, and core calls are the shipped bridge. */
const { Worker } = require('worker_threads')
const native = require(process.env.JSBAY_HARMONY_NODE)

const status = { INSTANCE_NOT_FOUND: 4, STALE_VALUE: 5 }
const samples = []

function expect(condition, message) {
  if (!condition) throw new Error(message)
}

function release(value) {
  if (value) native.release(value)
}

function expectStatus(operation, expected, message) {
  try {
    operation()
  } catch (error) {
    expect(error && error.status === expected, `${message}: expected ${expected}, received ${error && error.status}`)
    return
  }
  throw new Error(`${message}: did not throw`)
}

function rss() {
  if (global.gc) global.gc()
  return process.memoryUsage().rss
}

function sample(name) {
  const entry = { name, rss: rss(), engines: native.listEngines().length, resources: native.globalResourceUsage() }
  samples.push(entry)
  return entry
}

function assertGlobalIdle(name) {
  const usage = native.globalResourceUsage()
  expect(native.listEngines().length === 0, `${name}: live engine registry is not empty`)
  for (const field of ['timers', 'tsfnHandles', 'pendingCalls', 'nativeTasks', 'scriptTasks', 'pendingBytes']) {
    expect(usage[field] === 0n, `${name}: ${field} remains ${usage[field]}`)
  }
}

function attachLoop(engine) {
  let timer
  native.attachLoop(engine, (delay, generation) => {
    clearTimeout(timer)
    if (delay < 0) return
    timer = setTimeout(() => {
      try { native.runLoopTask(engine, generation) } catch (_) {}
    }, Number(delay))
  })
  return () => clearTimeout(timer)
}

function cycle(id, keepClosedValues) {
  const engine = native.create(id)
  const stop = attachLoop(engine)
  let escaped
  const binding = native.bind(engine, 'lifecycleEcho', (_this, input) => {
    escaped = native.retain(input)
    return native.newNumber(engine, native.toNumber(input) + 1)
  })
  const values = []
  try {
    for (let index = 0; index < 64; index += 1) values.push(native.newObject(engine))
    const result = native.evaluate(engine, 'lifecycleEcho(41)', 'lifecycle-cycle.js')
    try { expect(native.toNumber(result) === 42, `cycle ${id}: callback result`) } finally { release(result) }
    const pending = native.evaluate(engine, 'setTimeout(() => { globalThis.__late = 1 }, 60000); Promise.resolve(1); 0', 'lifecycle-pending.js')
    release(pending)
    expect(native.resourceUsage(engine).timers >= 1n, `cycle ${id}: pending timer was not registered`)
    for (const value of values) release(value)
    release(binding)
    native.close(engine)
    native.close(engine)
    stop()
    expectStatus(() => native.toNumber(escaped), status.STALE_VALUE, `cycle ${id}: retained value after close`)
    expectStatus(() => native.release(escaped), status.STALE_VALUE, `cycle ${id}: release retained value after close`)
    if (keepClosedValues) keepClosedValues.push(escaped)
    else escaped = undefined
  } catch (error) {
    try { native.close(engine) } catch (_) {}
    stop()
    throw error
  }
}

async function serialCreateClose() {
  const retainedAfterClose = []
  sample('serial-before')
  for (let batch = 0; batch < 2; batch += 1) {
    for (let round = 0; round < 300; round += 1) cycle(11000 + batch * 300 + round, retainedAfterClose)
    assertGlobalIdle(`serial-create-close-${batch}`)
    sample(`serial-after-${batch}`)
  }
  retainedAfterClose.length = 0
  if (global.gc) global.gc()
}

function residentGcPressure() {
  const engine = native.create(11500)
  const stop = attachLoop(engine)
  try {
    const warmup = native.evaluate(engine, '(() => new Array(4096).fill("warm").join(""))()', 'resident-gc.js')
    release(warmup)
    expect(native.runGc(engine) === true, 'resident: warmup GC')
    const before = native.getMemoryUsage(engine)
    for (let round = 0; round < 1000; round += 1) {
      const value = native.evaluate(engine, '(() => { const data = new Array(4096).fill("payload"); return data.length })()', 'resident-gc.js')
      try { expect(native.toNumber(value) === 4096, `resident: evaluation ${round}`) } finally { release(value) }
      if ((round + 1) % 100 === 0) expect(native.runGc(engine) === true, `resident: GC ${round}`)
    }
    expect(native.runGc(engine) === true, 'resident: final GC')
    const after = native.getMemoryUsage(engine)
    const allowance = 4n * 1024n * 1024n
    expect(after.memoryUsedSize <= before.memoryUsedSize + allowance, `resident: memoryUsedSize grew from ${before.memoryUsedSize} to ${after.memoryUsedSize}`)
    expect(after.mallocSize <= before.mallocSize + allowance, `resident: mallocSize grew from ${before.mallocSize} to ${after.mallocSize}`)
    sample('resident-after-gc')
    return { before, after, allowance }
  } finally {
    native.close(engine)
    stop()
  }
}

async function partialMultiInstanceClose() {
  const engines = []
  const stops = []
  sample('multi-before')
  try {
    for (let index = 0; index < 12; index += 1) {
      const engine = native.create(12000 + index)
      engines.push(engine)
      stops.push(attachLoop(engine))
      const value = native.evaluate(engine, `globalThis.owner=${index}; setTimeout(() => { globalThis.timer=${index} }, 60000); owner`, 'multi-instance.js')
      try { expect(native.toNumber(value) === index, `multi ${index}: initial evaluation`) } finally { release(value) }
    }
    expect(native.listEngines().length === 12, 'multi: expected twelve live engines')
    for (let index = 0; index < engines.length; index += 2) {
      native.close(engines[index])
      stops[index]()
    }
    expect(native.listEngines().length === 6, 'multi: half-close did not retain six survivors')
    for (let index = 1; index < engines.length; index += 2) {
      const value = native.evaluate(engines[index], `owner + ${index}`, 'multi-survivor.js')
      try { expect(native.toNumber(value) === index * 2, `multi ${index}: survivor evaluation`) } finally { release(value) }
      expect(native.resourceUsage(engines[index]).timers >= 1n, `multi ${index}: survivor timer`)
    }
    for (let index = 1; index < engines.length; index += 2) {
      native.close(engines[index])
      stops[index]()
    }
  } finally {
    for (let index = 0; index < engines.length; index += 1) {
      try { native.close(engines[index]) } catch (_) {}
      stops[index]()
    }
  }
  assertGlobalIdle('partial-multi-instance-close')
  sample('multi-after')
}

function runNoCloseWorker(addon, id, mode) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(__filename, { workerData: { addon, id, mode } })
    const timeout = setTimeout(() => reject(new Error(`worker ${id}: ready timeout`)), 5000)
    worker.once('message', (message) => {
      clearTimeout(timeout)
      if (!message || !message.ready) {
        reject(new Error(`worker ${id}: unexpected ready message`))
        return
      }
      worker.terminate().then((code) => resolve(code), reject)
    })
    worker.once('error', reject)
  })
}

async function workerEnvironmentCleanup() {
  sample('worker-before')
  for (let batch = 0; batch < 2; batch += 1) {
    for (let index = 0; index < 40; index += 1) {
      const id = 13000 + batch * 40 + index
      const code = await runNoCloseWorker(process.env.JSBAY_HARMONY_NODE, id, 'jsbay')
      expect(typeof code === 'number', `worker ${id}: termination has no exit code`)
      const engine = native.create(id)
      const value = native.evaluate(engine, '6 * 7', 'worker-reuse.js')
      try { expect(native.toNumber(value) === 42, `worker ${id}: instance id is not reusable`) } finally { release(value) }
      native.close(engine)
    }
    assertGlobalIdle(`worker-environment-cleanup-${batch}`)
    sample(`worker-after-${batch}`)
  }
}

async function workerRssControl() {
  sample('worker-control-before')
  for (let batch = 0; batch < 2; batch += 1) {
    for (let index = 0; index < 40; index += 1) {
      const code = await runNoCloseWorker('', 0, 'control')
      expect(typeof code === 'number', `control worker ${batch}:${index}: termination has no exit code`)
    }
    sample(`worker-control-after-${batch}`)
  }
}

async function main() {
  serialCreateClose()
  const residentGc = residentGcPressure()
  await partialMultiInstanceClose()
  await workerRssControl()
  await workerEnvironmentCleanup()
  assertGlobalIdle('complete')
  const first = samples[0].rss
  const final = samples[samples.length - 1].rss
  const result = { status: 'pass', cycles: 600, residentGc, multiInstances: 12, terminatedWorkers: 80, rssBytes: { first, final, delta: final - first }, samples }
  console.log(`LIFECYCLE_MEMORY_RESULT=${JSON.stringify(result, (_, value) => typeof value === 'bigint' ? value.toString() : value)}`)
}

if (!require('worker_threads').isMainThread) {
  const data = require('worker_threads').workerData
  if (data.mode === 'control') {
    new Array(2048).fill(1)
    require('worker_threads').parentPort.postMessage({ ready: true })
  } else {
    const n = require(data.addon)
    const engine = n.create(data.id)
    n.attachLoop(engine, () => {})
    const value = n.evaluate(engine, 'setInterval(() => {}, 60000); new Array(2048).fill(1); 0', 'worker-no-close.js')
    n.release(value)
    require('worker_threads').parentPort.postMessage({ ready: true })
  }
} else {
  main().catch((error) => {
    console.error(`LIFECYCLE_MEMORY_FAILURE=${error && error.stack ? error.stack : error}`)
    process.exitCode = 1
  })
}
