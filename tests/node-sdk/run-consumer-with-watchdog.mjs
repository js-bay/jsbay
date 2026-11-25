import { spawn } from 'node:child_process'
import { constants as osConstants } from 'node:os'
import { writeSync } from 'node:fs'

const [timeoutText, command, ...args] = process.argv.slice(2)
const timeoutMs = Number(timeoutText)
if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || !command) {
  writeSync(2, 'usage: run-consumer-with-watchdog.mjs <timeout-ms> <command> [args...]\n')
  process.exit(2)
}

const consumer = spawn(command, args, { stdio: ['inherit', 'pipe', 'pipe'], env: process.env })
consumer.stdout.pipe(process.stdout)
consumer.stderr.pipe(process.stderr)
let timedOut = false
let finished = false
const timeout = setTimeout(onTimeout, timeoutMs)

consumer.once('error', error => {
  if (finished) return
  finished = true
  clearTimeout(timeout)
  writeSync(2, `consumer process could not start: ${error.message}\n`)
  process.exitCode = 127
})

consumer.once('close', (code, signal) => {
  if (finished || timedOut) return
  finished = true
  clearTimeout(timeout)
  process.exitCode = code ?? (signal ? 128 + (osConstants.signals[signal] ?? 1) : 1)
})

function onTimeout() {
  if (finished || timedOut) return
  timedOut = true
  writeSync(2, `consumer exceeded its ${timeoutMs}ms watchdog\n`)
  if (process.platform !== 'darwin' || !consumer.pid) {
    failAndKillConsumer()
    return
  }

  const sampler = spawn('sample', [String(consumer.pid), '1'], { stdio: ['ignore', 'pipe', 'pipe'] })
  sampler.stdout.on('data', chunk => writeSync(2, chunk))
  sampler.stderr.on('data', chunk => writeSync(2, chunk))
  const sampleTimeout = setTimeout(() => {
    writeSync(2, 'process sample exceeded its 5000ms limit; sending SIGKILL\n')
    sampler.kill('SIGKILL')
    failAndKillConsumer()
  }, 5000)
  sampler.once('error', error => {
    clearTimeout(sampleTimeout)
    writeSync(2, `process sample could not start: ${error.message}\n`)
    failAndKillConsumer()
  })
  sampler.once('close', (code, signal) => {
    clearTimeout(sampleTimeout)
    writeSync(2, `process sample finished with code ${code ?? 'null'} and signal ${signal ?? 'none'}\n`)
    failAndKillConsumer()
  })
}

function failAndKillConsumer() {
  if (finished) return
  finished = true
  clearTimeout(timeout)
  consumer.kill('SIGKILL')
  process.exitCode = 1
  process.exit(1)
}
