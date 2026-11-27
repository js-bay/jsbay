import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { getNpmInvocation } from './npm-cli-invocation.mjs'

const run = promisify(execFile)
const [version] = process.argv.slice(2)
assert(process.platform === 'win32' && process.arch === 'x64', 'Run this consumer on Windows x64')
assert(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version ?? ''), 'Pass the published package version')

const npm = getNpmInvocation()
const registry = process.env.NPM_REGISTRY || 'https://registry.npmjs.org'
const work = await mkdtemp(join(tmpdir(), 'jsbay-published-windows-'))
const installDir = join(work, 'consumer')
const packageFile = join(installDir, 'package.json')

try {
  await mkdir(installDir, { recursive: true })
  await writeFile(packageFile, JSON.stringify({ name: 'jsbay-published-consumer', private: true }))
  const npmCache = process.env.JSBAY_PUBLISHED_NPM_CACHE ?? join(work, 'npm-cache')
  const npmUserConfig = process.env.JSBAY_PUBLISHED_NPM_USERCONFIG
  const npmConfigArgs = npmUserConfig ? ['--userconfig', npmUserConfig] : []
  await run(npm.command, [...npm.args, 'install', '--prefix', installDir, '--registry', registry,
    '--cache', npmCache, ...npmConfigArgs, '--prefer-offline', '--include=optional', '--ignore-scripts', '--no-audit', '--no-fund',
    '--save-exact', `@jsbay/quickjsng@${version}`])

  const env = {
    ...process.env,
    JSBAY_NODE_PACKAGE_ROOT: packageFile,
    JSBAY_NODE_PACKAGE: '@jsbay/quickjsng',
    JSBAY_NODE_PUBLIC_VERSION: version,
  }
  const nodeConsumer = fileURLToPath(new URL('./package_consumer.mjs', import.meta.url))
  const { stdout } = await run(process.execPath, [nodeConsumer], { env })
  process.stdout.write(stdout)
  const electronConsumer = fileURLToPath(new URL('./electron-packaged-consumer.mjs', import.meta.url))
  const { stdout: electronOutput } = await run(process.execPath, [electronConsumer, '--installed-prefix', installDir])
  process.stdout.write(electronOutput)
} finally {
  await rm(work, { recursive: true, force: true })
}
