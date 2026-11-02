'use strict'

const native = require(process.env.JSBAY_HARMONY_NODE)
const testCase = process.argv[2]

function expect(value, message) { if (!value) throw new Error(message) }
function release(value) { if (value) native.release(value) }
function fresh(id) {
  const engine = native.create(id)
  expect(native.setExecutionBudget(engine, 40n), 'setExecutionBudget rejected')
  return engine
}
function expectInterrupted(operation, message) {
  let interrupted = false
  try { operation() } catch (_) { interrupted = true }
  expect(interrupted, message)
}
function attachLoop(engine, onError) {
  native.attachLoop(engine, (delay, generation) => {
    setTimeout(() => {
      try { native.runLoopTask(engine, generation) } catch (error) { onError(error) }
    }, Math.max(0, Number(delay)))
  })
}

async function timerInfinite() {
  const engine = fresh(17801)
  try {
    await new Promise(resolve => {
      attachLoop(engine, () => resolve())
      const result = native.evaluate(engine, 'setTimeout(() => { globalThis.__timerStarted = 1; for (;;) {} }, 0); 0', 'timer-infinite.js')
      release(result)
      setTimeout(resolve, 100)
    })
    const started = native.evaluate(engine, '__timerStarted', 'timer-started.js')
    try { expect(native.toNumber(started) === 1, 'timer callback did not begin') } finally { release(started) }
    const resultAfter = native.evaluate(engine, '6 * 7', 'timer-recovery.js')
    try { expect(native.toNumber(resultAfter) === 42, 'timer recovery failed') } finally { release(resultAfter) }
  } finally { native.close(engine) }
}

async function promiseInfinite() {
  const engine = fresh(17802)
  try {
    attachLoop(engine, () => {})
    const started = native.evaluate(engine, 'Promise.resolve().then(function loop(){ globalThis.__promiseCount = (globalThis.__promiseCount || 0) + 1; return Promise.resolve().then(loop) }); setTimeout(() => { globalThis.__promiseAfter = 1 }, 10); 0', 'promise-infinite.js')
    release(started)
    await new Promise(resolve => setTimeout(resolve, 150))
    const after = native.evaluate(engine, '__promiseAfter', 'promise-after.js')
    try { expect(native.toNumber(after) === 1, 'Promise chain prevented later timer work') } finally { release(after) }
    const result = native.evaluate(engine, '6 * 7', 'promise-recovery.js')
    try { expect(native.toNumber(result) === 42, 'Promise recovery failed') } finally { release(result) }
  } finally { native.close(engine) }
}

function valueEntrypoints() {
  const engine = fresh(17803)
  try {
    const functionValue = native.evaluate(engine, '(function(){ for (;;) {} })', 'call-loop.js')
    const thisValue = native.undefined(engine)
    try { expectInterrupted(() => native.call(functionValue, thisValue, []), 'Value.call did not interrupt') } finally { release(functionValue); release(thisValue) }

    const getterObject = native.evaluate(engine, '({ get x(){ for (;;) {} } })', 'getter-loop.js')
    try { expectInterrupted(() => native.get(getterObject, 'x'), 'Value.get getter did not interrupt') } finally { release(getterObject) }

    const jsonObject = native.evaluate(engine, '({ toJSON(){ for (;;) {} } })', 'json-loop.js')
    try { expectInterrupted(() => native.toJson(jsonObject), 'Value.toJson did not interrupt') } finally { release(jsonObject) }

    const result = native.evaluate(engine, '6 * 7', 'entrypoint-recovery.js')
    try { expect(native.toNumber(result) === 42, 'Value entrypoint recovery failed') } finally { release(result) }
  } finally { native.close(engine) }
}

function nestedBudget() {
  const engine = fresh(17804)
  try {
    const callback = native.bind(engine, 'nested', () => {
      let interrupted = false
      try { native.evaluate(engine, 'for (;;) {}', 'nested-loop.js') } catch (_) { interrupted = true }
      expect(interrupted, 'nested evaluation did not interrupt')
      return native.undefined(engine)
    })
    const started = Date.now()
    const result = native.evaluate(engine, 'const until = Date.now() + 30; while (Date.now() < until) {} nested(); 0', 'nested-outer.js')
    const elapsed = Date.now() - started
    try { expect(native.toNumber(result) === 0, 'nested outer result') } finally { release(result); release(callback) }
    expect(elapsed < 70, `nested entry reset the outer budget (${elapsed}ms)`)
  } finally { native.close(engine) }
}

function manualShorter() {
  const engine = fresh(17805)
  try {
    expect(native.setExecutionTimeLimit(engine, 15n), 'manual limit rejected')
    expect(native.setExecutionBudget(engine, 0n), 'budget disable rejected')
    const started = Date.now()
    expectInterrupted(() => native.evaluate(engine, 'for (;;) {}', 'manual-shorter.js'), 'manual limit was cleared by budget cleanup')
    expect(Date.now() - started < 100, 'manual short deadline was not preferred')
    expect(native.setExecutionTimeLimit(engine, 0n), 'manual limit reset rejected')
    const result = native.evaluate(engine, '6 * 7', 'manual-recovery.js')
    try { expect(native.toNumber(result) === 42, 'manual recovery failed') } finally { release(result) }
  } finally { native.close(engine) }
}

function syncWaitBudget() {
  const engine = fresh(17806)
  try {
    const wait = native.bindSync(engine, 'waitForever', 1000n, () => {})
    const started = Date.now()
    expectInterrupted(() => native.evaluate(engine, 'waitForever()', 'sync-budget.js'), 'budget did not bound native synchronous wait')
    expect(Date.now() - started < 150, 'native synchronous wait ignored effective budget deadline')
    release(wait)
  } finally { native.close(engine) }
}

const cases = { timerInfinite, promiseInfinite, valueEntrypoints, nestedBudget, manualShorter, syncWaitBudget }
Promise.resolve(cases[testCase] ? cases[testCase]() : Promise.reject(new Error(`unknown case ${testCase}`))).then(() => {
  console.log(`BUDGET_CASE=${testCase}:pass`)
}, error => {
  console.error(error && error.stack || String(error))
  process.exitCode = 1
})
