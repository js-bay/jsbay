'use strict'

const assert = require('node:assert/strict')
const { spawn } = require('node:child_process')
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads')

const addonPath = process.env.JSBAY_HARMONY_NODE
if (!addonPath) throw new Error('JSBAY_HARMONY_NODE must name a compiled N-API addon')
const native = require(addonPath)
const Status = { completed: 0, exception: 1, cancelled: 2 }

function attachLoop(engine) {
  let timer
  let loopGeneration
  native.attachLoop(engine, (delay, generation) => {
    loopGeneration = generation
    if (timer !== undefined) clearTimeout(timer)
    if (delay < 0) return
    timer = setTimeout(() => {
      timer = undefined
      native.runLoopTask(engine, generation)
    }, Math.max(0, Number(delay)))
  })
  return { stop: () => { if (timer !== undefined) clearTimeout(timer) }, generation: () => loopGeneration }
}

function generation(id) {
  const snapshot = native.snapshotEngine(id)
  assert(snapshot && typeof snapshot.generation === 'bigint', 'missing core generation')
  return snapshot.generation
}

function number(engine, source) {
  const value = native.evaluate(engine, source, 'submission-check.js')
  try { return native.toNumber(value) } finally { native.release(value) }
}

function submit(engine, source, filename, callback) {
  assert.equal(native.postScript(engine, source, filename, callback), true, `rejected ${filename}`)
}

function fence(engine, seal, callback) {
  assert.equal(native.postFence(engine, seal, callback), true, 'rejected fence')
}

async function fifoReentrant() {
  const id = 28101
  const engine = native.create(id)
  const loop = attachLoop(engine)
  const events = []
  let binding
  try {
    let resolveFinal
    let rejectFinal
    const finished = new Promise((resolve, reject) => { resolveFinal = resolve; rejectFinal = reject })
    binding = native.bind(engine, 'enqueueFromHost', () => {
      submit(engine, 'globalThis.__order = globalThis.__order * 10 + 4', 'reentrant.js', outcome => {
        events.push(`C:${outcome.status}`)
      })
      fence(engine, false, outcome => {
        events.push(`G:${outcome.status}`)
        try {
          assert.equal(number(engine, 'globalThis.__order'), 234)
          assert.deepEqual(events, ['A:0', 'B:0', 'F:0', 'C:0', 'G:0'])
          resolveFinal()
        } catch (error) { rejectFinal(error) }
      })
      return native.undefined(engine)
    })
    submit(engine, 'globalThis.__order = 1; Promise.resolve().then(() => { globalThis.__order = 2 }); enqueueFromHost()', 'first.js', outcome => {
      events.push(`A:${outcome.status}`)
    })
    submit(engine, 'if (globalThis.__order !== 2) throw Error("checkpoint missing"); globalThis.__order = 23', 'second.js', outcome => {
      events.push(`B:${outcome.status}`)
    })
    fence(engine, false, outcome => { events.push(`F:${outcome.status}`) })
    await finished
    assert.equal(events.filter(event => event.startsWith('C:')).length, 1, 'reentrant completion missing')
    assert.equal(events.length, 5, 'each admitted item must settle once')
  } finally {
    if (binding) native.release(binding)
    loop.stop()
    native.close(engine)
  }
}

async function pendingClose() {
  const engine = native.create(28102)
  const loop = attachLoop(engine)
  const outcomes = []
  try {
    let settle
    const settled = new Promise(resolve => { settle = resolve })
    submit(engine, 'globalThis.__pending = 1', 'pending.js', outcome => { outcomes.push(outcome); settle() })
    native.close(engine)
    await settled
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(outcomes.length, 1, 'close must settle pending callback exactly once')
    assert.equal(outcomes[0].status, Status.cancelled, 'close must cancel pending work')
  } finally {
    loop.stop()
    native.close(engine)
  }
}

async function throwingCallback() {
  const engine = native.create(28103)
  const loop = attachLoop(engine)
  const outcomes = []
  try {
    await new Promise((resolve, reject) => {
      submit(engine, 'globalThis.__throws = 1', 'throw-callback.js', () => {
        outcomes.push('first')
        throw new Error('intentional callback failure')
      })
      submit(engine, 'globalThis.__throws += 1', 'after-callback.js', outcome => {
        outcomes.push(`second:${outcome.status}`)
      })
      fence(engine, false, outcome => {
        outcomes.push(`fence:${outcome.status}`)
        try { assert.equal(number(engine, 'globalThis.__throws'), 2); resolve() } catch (error) { reject(error) }
      })
    })
    assert.deepEqual(outcomes, ['first', 'second:0', 'fence:0'])
  } finally { loop.stop(); native.close(engine) }
}

async function sealAdmission() {
  const id = 28104
  const engine = native.create(id)
  const loop = attachLoop(engine)
  try {
    const coreGeneration = generation(id)
    assert.equal(native.beginShutdown(id, coreGeneration, 1000n), true)
    const drained = new Promise((resolve, reject) => {
      submit(engine, 'globalThis.__terminal = 41', 'terminal.js', outcome => {
        if (outcome.status !== Status.completed) reject(new Error(`terminal status ${outcome.status}`))
      })
      fence(engine, true, outcome => outcome.status === Status.completed ? resolve() : reject(new Error(`fence status ${outcome.status}`)))
    })
    assert.equal(native.postScript(engine, 'globalThis.__late = 1', 'late.js', () => {}), false, 'sealed queue accepted ordinary work')
    assert.throws(() => number(engine, '6 * 7'), 'sealed engine accepted direct evaluation')
    await drained
    const status = native.shutdownStatus(id, coreGeneration)
    assert(status && status.phase === 3, `expected drained phase, got ${status && status.phase}`)
  } finally { loop.stop(); native.close(engine) }
}

async function staleGeneration() {
  const id = 28105
  const old = native.create(id)
  const oldGeneration = generation(id)
  native.close(old)
  const replacement = native.create(id)
  const loop = attachLoop(replacement)
  try {
    assert.notEqual(generation(id), oldGeneration, 'id reuse did not change core generation')
    assert.equal(native.beginShutdown(id, oldGeneration, 1000n), false, 'old generation began replacement shutdown')
    assert.equal(native.shutdownStatus(id, oldGeneration), null, 'old generation observed replacement status')
    assert.equal(native.cancelEngine(id, oldGeneration), false, 'old generation cancelled replacement')
    await new Promise((resolve, reject) => {
      submit(replacement, 'globalThis.__replacement = 42', 'replacement.js', outcome => {
        if (outcome.status !== Status.completed) reject(new Error(`replacement status ${outcome.status}`))
      })
      fence(replacement, false, outcome => outcome.status === Status.completed ? resolve() : reject(new Error(`replacement fence ${outcome.status}`)))
    })
    assert.equal(number(replacement, 'globalThis.__replacement'), 42)
  } finally { loop.stop(); native.close(replacement) }
}

async function ownerWorker() {
  if (workerData.role === 'cancel') {
    const state = new Int32Array(workerData.signal)
    parentPort.postMessage({ type: 'ready' })
    if (Atomics.wait(state, 0, 0, 2000) === 'timed-out') throw new Error('submission did not start')
    const accepted = native.cancelEngine(workerData.id, BigInt(workerData.generation))
    Atomics.store(state, 1, accepted ? 1 : -1)
    Atomics.notify(state, 1)
    return
  }
  if (workerData.role === 'deadline') {
    const state = new Int32Array(workerData.signal)
    parentPort.postMessage({ type: 'ready' })
    if (Atomics.wait(state, 0, 0, 2000) !== 'ok') throw new Error('sync wait did not start')
    const accepted = native.beginShutdown(workerData.id, BigInt(workerData.generation), 40n)
    parentPort.postMessage({ type: 'begun', accepted })
    return
  }
  const { id } = workerData
  const engine = native.create(id)
  const loop = attachLoop(engine)
  const startupTimeout = setTimeout(() => { throw new Error('owner submission did not settle') }, 2200)
  try {
    const coreGeneration = generation(id)
    await new Promise((resolve, reject) => {
      submit(engine, 'globalThis.__ownerValue = 1', 'owner-start.js', outcome => {
        if (outcome.status !== Status.completed) reject(new Error(`owner start ${outcome.status}`))
      })
      fence(engine, false, outcome => outcome.status === Status.completed ? resolve() : reject(new Error(`owner fence ${outcome.status}`)))
    })
    clearTimeout(startupTimeout)
    parentPort.postMessage({ type: 'ready', coreGeneration: coreGeneration.toString(), loopGeneration: String(loop.generation()) })
    parentPort.on('message', message => {
      if (message === 'check') {
        submit(engine, 'globalThis.__ownerValue = 42', 'owner-check.js', outcome => {
          if (outcome.status !== Status.completed) throw new Error(`owner check ${outcome.status}`)
        })
        fence(engine, false, outcome => {
          if (outcome.status !== Status.completed) throw new Error(`owner check fence ${outcome.status}`)
          parentPort.postMessage({ type: 'checked', value: number(engine, 'globalThis.__ownerValue') })
        })
      } else if (message === 'close') {
        loop.stop()
        native.close(engine)
        parentPort.postMessage({ type: 'closed' })
      }
    })
  } catch (error) {
    clearTimeout(startupTimeout)
    loop.stop()
    native.close(engine)
    throw error
  }
}

function waitMessage(worker, type) {
  return new Promise((resolve, reject) => {
    const onMessage = message => {
      if (message.type !== type) return
      cleanup()
      resolve(message)
    }
    const onError = error => { cleanup(); reject(error) }
    const onExit = code => { cleanup(); reject(new Error(`owner exited before ${type}: ${code}`)) }
    const cleanup = () => {
      worker.off('message', onMessage)
      worker.off('error', onError)
      worker.off('exit', onExit)
    }
    worker.on('message', onMessage)
    worker.once('error', onError)
    worker.once('exit', onExit)
  })
}

async function multiOwner() {
  const seed = native.create(28106)
  native.close(seed)
  const first = new Worker(__filename, { workerData: { role: 'owner', id: 28107 }, env: process.env })
  const second = new Worker(__filename, { workerData: { role: 'owner', id: 28108 }, env: process.env })
  try {
    const [a, b] = await Promise.all([waitMessage(first, 'ready'), waitMessage(second, 'ready')])
    assert(a.coreGeneration !== a.loopGeneration || b.coreGeneration !== b.loopGeneration,
      'test did not create a core generation distinct from loop generation')
    const firstClosed = waitMessage(first, 'closed')
    first.postMessage('close')
    await firstClosed
    const checked = waitMessage(second, 'checked')
    second.postMessage('check')
    assert.equal((await checked).value, 42, 'surviving owner stopped after another owner closed')
    const secondClosed = waitMessage(second, 'closed')
    second.postMessage('close')
    await secondClosed
  } finally { await Promise.allSettled([first.terminate(), second.terminate()]) }
}

async function tightenExistingSyncWait() {
  const id = 28109
  const engine = native.create(id)
  const loop = attachLoop(engine)
  const signal = new Int32Array(new SharedArrayBuffer(4))
  const coreGeneration = generation(id)
  const worker = new Worker(__filename, {
    workerData: { role: 'deadline', id, generation: coreGeneration.toString(), signal: signal.buffer },
    env: process.env
  })
  let binding
  try {
    assert.equal(native.setExecutionBudget(engine, 0n), true)
    binding = native.bindSync(engine, 'waitForever', 1000n, () => {
      Atomics.store(signal, 0, 1)
      Atomics.notify(signal, 0)
    })
    await waitMessage(worker, 'ready')
    const started = Date.now()
    assert.throws(() => native.evaluate(engine, 'waitForever()', 'existing-sync-wait.js'),
      'shutdown did not interrupt the pending synchronous native request')
    const elapsed = Date.now() - started
    assert(elapsed < 500, `beginShutdown did not tighten existing wait (${elapsed} ms)`)
    const begun = await waitMessage(worker, 'begun')
    assert.equal(begun.accepted, true, 'cross-thread shutdown begin rejected')
  } finally {
    if (binding) native.release(binding)
    loop.stop()
    native.close(engine)
    await worker.terminate()
  }
}

async function inflightCancellation() {
  const id = 28111
  const engine = native.create(id)
  const loop = attachLoop(engine)
  const signal = new SharedArrayBuffer(8)
  const state = new Int32Array(signal)
  const worker = new Worker(__filename, { workerData: { role: 'cancel', id, generation: generation(id).toString(), signal } })
  let binding
  try {
    await waitMessage(worker, 'ready')
    binding = native.bind(engine, 'signalSubmissionStarted', () => {
      Atomics.store(state, 0, 1)
      Atomics.notify(state, 0)
      if (Atomics.wait(state, 1, 0, 2000) === 'timed-out') throw new Error('cancellation was not acknowledged')
      assert.equal(Atomics.load(state, 1), 1, 'cross-thread cancellation rejected')
      return native.undefined(engine)
    })
    const outcome = await new Promise(resolve => {
      submit(engine, 'signalSubmissionStarted(); for (;;) {}', 'inflight-cancel.js', resolve)
    })
    assert.equal(outcome.status, Status.cancelled, 'in-flight generation cancellation must report cancelled')
  } finally {
    if (binding) native.release(binding)
    loop.stop()
    native.close(engine)
    await worker.terminate()
  }
}

async function shutdownDeadlineOutcome() {
  const id = 28112
  const engine = native.create(id)
  const loop = attachLoop(engine)
  try {
    assert.equal(native.beginShutdown(id, generation(id), 40n), true)
    const outcome = await new Promise(resolve => submit(engine, 'for (;;) {}', 'shutdown-deadline.js', resolve))
    assert.equal(outcome.status, Status.cancelled, 'shutdown deadline must cancel in-flight submission')
  } finally { loop.stop(); native.close(engine) }
}

async function recoverableExceptions() {
  const engine = native.create(28113)
  const loop = attachLoop(engine)
  try {
    const thrown = await new Promise(resolve => submit(engine, 'throw Error("expected")', 'ordinary-throw.js', resolve))
    assert.equal(thrown.status, Status.exception)
    assert.equal(native.setExecutionBudget(engine, 20n), true)
    const budget = await new Promise(resolve => submit(engine, 'for (;;) {}', 'entry-budget.js', resolve))
    assert.equal(budget.status, Status.exception, 'recoverable execution budget is not lifecycle cancellation')
    const recovered = await new Promise(resolve => submit(engine, '6 * 7', 'after-budget.js', resolve))
    assert.equal(recovered.status, Status.completed)
  } finally { loop.stop(); native.close(engine) }
}

const cases = { fifoReentrant, multiOwner, pendingClose, throwingCallback, sealAdmission, staleGeneration, tightenExistingSyncWait, inflightCancellation, shutdownDeadlineOutcome, recoverableExceptions }

async function runMatrix() {
  let failures = 0
  for (const name of Object.keys(cases)) {
    const result = await new Promise(resolve => {
      const child = spawn(process.execPath, ['--expose-gc', __filename, '--case', name], { env: process.env })
      let output = ''
      let timedOut = false
      const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL') }, 3000)
      child.stdout.on('data', chunk => { output += chunk })
      child.stderr.on('data', chunk => { output += chunk })
      child.once('error', error => { clearTimeout(timer); resolve({ name, code: null, output: String(error), timedOut }) })
      child.once('close', code => { clearTimeout(timer); resolve({ name, code, output, timedOut }) })
    })
    process.stdout.write(result.output)
    if (result.code !== 0 || result.timedOut || !result.output.includes(`SUBMISSION_CASE=${name}:pass`)) {
      failures += 1
      console.error(`SUBMISSION_CASE=${name}:fail exit=${result.code} timeout=${result.timedOut}`)
    }
  }
  console.log(`SUBMISSION_MATRIX=${failures === 0 ? 'pass' : 'fail'} cases=${Object.keys(cases).length} failed=${failures}`)
  if (failures) process.exitCode = 1
}

if (!isMainThread) {
  ownerWorker().catch(error => { console.error(error.stack || String(error)); process.exitCode = 1 })
} else if (process.argv[2] === '--case') {
  const name = process.argv[3]
  if (!Object.hasOwn(cases, name)) throw new Error(`unknown case ${name}`)
  let timeout
  const guard = new Promise((_, reject) => {
    timeout = setTimeout(() => reject(new Error(`${name} did not settle`)), 2500)
  })
  Promise.race([cases[name](), guard]).then(() => {
    clearTimeout(timeout)
    console.log(`SUBMISSION_CASE=${name}:pass`)
  }, error => {
    clearTimeout(timeout)
    console.error(error.stack || String(error))
    process.exitCode = 1
  })
} else {
  runMatrix().catch(error => { console.error(error.stack || String(error)); process.exitCode = 1 })
}
