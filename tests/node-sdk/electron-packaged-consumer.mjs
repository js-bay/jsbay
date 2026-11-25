import assert from 'node:assert/strict'
import { spawn, execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { cp, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { cleanupTempDirectory } from './cleanup-temp-directory.mjs'
import { extractPackage } from './extract-npm-package.mjs'
import { packageElectronApp } from './run-electron-packager.mjs'
import { electronExecutableName } from './electron-packager-options.mjs'
import { promisify } from 'node:util'

const run = promisify(execFile)
const args = process.argv.slice(2)
const electronVersion = '44.11.5'
if (args.length === 1 && args[0] === '--print-version') {
  process.stdout.write(`${electronVersion}\n`)
  process.exit(0)
}
assert(process.platform === 'win32' && process.arch === 'x64', 'Run this consumer on Windows x64')
const installedPrefix = args[0] === '--installed-prefix' ? resolve(args[1] ?? '') : undefined
const tarballs = installedPrefix ? [] : args.map(value => resolve(value))
assert(installedPrefix || tarballs.length === 2, 'Pass either --installed-prefix <directory> or both npm tarballs')
const npmCli = join(dirname(process.execPath), 'node_modules', 'npm', 'bin', 'npm-cli.js')
assert(existsSync(npmCli), `npm CLI not found at ${npmCli}`)
const work = await mkdtemp(join(tmpdir(), 'jsbay-electron-packaged-'))
let operationError
const toolsDir = join(work, 'tools')
const appDir = join(work, 'app')
const outputDir = join(work, 'dist')

function runPackagedApp(executable) {
  return new Promise((resolveRun, rejectRun) => {
    const resultFile = join(work, 'electron-result.txt')
    const child = spawn(executable, ['--no-sandbox', '--disable-gpu', '--js-flags=--expose-gc'], {
      windowsHide: true,
      env: { ...process.env, JSBAY_ELECTRON_RESULT: resultFile },
    })
    let output = ''
    const timer = setTimeout(() => {
      child.kill()
      rejectRun(new Error(`Packaged Electron app timed out:\n${output}`))
    }, 60000)
    child.stdout.setEncoding('utf8').on('data', chunk => { output += chunk })
    child.stderr.setEncoding('utf8').on('data', chunk => { output += chunk })
    child.once('error', error => {
      clearTimeout(timer)
      rejectRun(error)
    })
    child.once('close', (code, signal) => {
      clearTimeout(timer)
      if (code !== 0) rejectRun(new Error(`Packaged Electron exited with ${code ?? signal}:\n${output}`))
      else resolveRun({ output, resultFile })
    })
  })
}

const electronWorkerSource = "const { parentPort, workerData } = require('node:worker_threads'); const { Engine } = require(workerData.addonPath); let engine = Engine.create(); const closed = engine.closeAsync(); engine = null; global.gc(); closed.then(() => { global.gc(); parentPort.postMessage('closed') }, error => { throw error })"

try {
  let main
  let platform
  if (installedPrefix) {
    const installedNodeModules = join(installedPrefix, 'node_modules', '@jsbay')
    const appNodeModules = join(appDir, 'node_modules', '@jsbay')
    await mkdir(appNodeModules, { recursive: true })
    await cp(join(installedNodeModules, 'quickjsng'), join(appNodeModules, 'quickjsng'), { recursive: true })
    await cp(join(installedNodeModules, 'quickjsng-win32-x64'), join(appNodeModules, 'quickjsng-win32-x64'), { recursive: true })
    main = JSON.parse(await readFile(join(appNodeModules, 'quickjsng', 'package.json'), 'utf8'))
    platform = JSON.parse(await readFile(join(appNodeModules, 'quickjsng-win32-x64', 'package.json'), 'utf8'))
  } else {
    main = await extractPackage(tarballs[0], join(appDir, 'node_modules', '@jsbay', 'quickjsng'))
    platform = await extractPackage(tarballs[1], join(appDir, 'node_modules', '@jsbay', 'quickjsng-win32-x64'))
  }
  assert.equal(main.name, '@jsbay/quickjsng')
  assert.equal(platform.name, '@jsbay/quickjsng-win32-x64')
  assert.equal(main.optionalDependencies[platform.name], main.version)
  assert.equal(platform.version, main.version)

  await writeFile(join(appDir, 'package.json'), JSON.stringify({
    name: 'jsbay-electron-smoke',
    version: '1.0.0',
    main: 'main.cjs',
    dependencies: { [main.name]: main.version, [platform.name]: platform.version },
  }, null, 2))
  await writeFile(join(appDir, 'main.cjs'), [
    "const { app } = require('electron')",
    "const assert = require('node:assert/strict')",
    "const { writeFileSync } = require('node:fs')",
    "const { Worker } = require('node:worker_threads')",
    "const { Engine } = require('@jsbay/quickjsng')",
    'function workerCloseAsyncGc(addonPath) {',
    '  return new Promise((resolve, reject) => {',
    `    const worker = new Worker(${JSON.stringify(electronWorkerSource)}, { eval: true, workerData: { addonPath } })`,
    "    const timer = setTimeout(() => { void worker.terminate(); reject(new Error('Electron worker closeAsync timed out')) }, 5000)",
    "    worker.once('error', error => { clearTimeout(timer); reject(error) })",
    "    worker.once('message', message => { clearTimeout(timer); assert.equal(message, 'closed'); resolve() })",
    '  })',
    '}',
    'async function run() {',
    "  const engine = Engine.create()",
    "  assert.equal(engine.evaluate('6 * 7'), 42, 'packaged addon evaluates JavaScript')",
    '  await engine.closeAsync()',
    "  assert.throws(() => engine.evaluate('1'), /closed/, 'closed engines reject later calls')",
    "  await workerCloseAsyncGc(require.resolve('@jsbay/quickjsng'))",
    '  for (let index = 0; index < 3; index++) { global.gc(); await new Promise(resolve => setImmediate(resolve)) }',
    "  writeFileSync(process.env.JSBAY_ELECTRON_RESULT, 'JSBAY_ELECTRON_PACKAGED_OK')",
    '}',
    "app.whenReady().then(() => run().then(() => app.exit(0), error => { console.error(error); app.exit(1) }))",
  ].join('\n'))

  await run(process.execPath, [npmCli, 'install', '--prefix', toolsDir, '--no-save', '--no-audit', '--no-fund',
    '@electron/packager@20.3.0'])
  const bundles = await packageElectronApp(
    join(toolsDir, 'node_modules', '@electron', 'packager', 'dist', 'index.js'),
    appDir,
    outputDir,
    electronVersion,
  )
  assert.equal(bundles.length, 1)
  const appPath = bundles[0]
  const appAsar = join(appPath, 'resources', 'app.asar')
  const unpackedAddon = join(appPath, 'resources', 'app.asar.unpacked', 'node_modules', '@jsbay', 'quickjsng-win32-x64', 'jsbay_node.node')
  const electronExe = join(appPath, `${electronExecutableName}.exe`)
  await readFile(appAsar)
  await readFile(unpackedAddon)
  const { output, resultFile } = await runPackagedApp(electronExe)
  assert.equal(await readFile(resultFile, 'utf8'), 'JSBAY_ELECTRON_PACKAGED_OK', output)
  console.log(`Packaged Windows x64 Electron ${electronVersion} loaded ${platform.name} from app.asar.unpacked`)
} catch (error) {
  operationError = error
  throw error
} finally {
  await cleanupTempDirectory(work, operationError)
}
