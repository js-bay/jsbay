'use strict'

const { spawn } = require('child_process')
const path = require('path')
const cases = ['timerInfinite', 'promiseInfinite', 'valueEntrypoints', 'nestedBudget', 'manualShorter', 'syncWaitBudget']
const timeoutMs = 3000

function run(name) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['--expose-gc', path.join(__dirname, 'budget_matrix_consumer.cjs'), name], { env: process.env })
    let output = ''
    child.stdout.on('data', data => { output += data })
    child.stderr.on('data', data => { output += data })
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`${name} exceeded ${timeoutMs}ms\n${output}`)) }, timeoutMs)
    child.on('exit', code => {
      clearTimeout(timer)
      if (code === 0 && output.includes(`BUDGET_CASE=${name}:pass`)) resolve(output)
      else reject(new Error(`${name} failed with ${code}\n${output}`))
    })
  })
}

;(async () => {
  for (const name of cases) process.stdout.write(await run(name))
  console.log('BUDGET_MATRIX=pass')
})().catch(error => { console.error(error.stack || String(error)); process.exitCode = 1 })
