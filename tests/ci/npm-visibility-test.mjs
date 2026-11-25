import assert from 'node:assert/strict'
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { execFile, execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import http from 'node:http'
import { once } from 'node:events'
import { promisify } from 'node:util'
import test from 'node:test'
import { getNpmInvocation } from '../node-sdk/npm-cli-invocation.mjs'

const root = resolve(import.meta.dirname, '../..')
const helper = join(root, 'tests/node-sdk/wait-for-published-npm.mjs')
const execFileAsync = promisify(execFile)
const version = '0.1.1-rc.2'
const packageName = '@jsbay/quickjs'
const platformPackage = '@jsbay/quickjslinuxx64'
const platformPackages = [
  '@jsbay/quickjsmacosarm64',
  '@jsbay/quickjsmacosx64',
  '@jsbay/quickjslinuxarm64',
  '@jsbay/quickjslinuxx64',
]

test('uses npm-cli.js for the default Windows npm invocation and preserves injected npm commands', () => {
  assert.deepEqual(getNpmInvocation({ platform: 'win32', execPath: 'C:\\node\\node.exe' }), {
    command: 'C:\\node\\node.exe',
    args: ['C:\\node\\node_modules\\npm\\bin\\npm-cli.js'],
  })
  assert.deepEqual(getNpmInvocation({ platform: 'win32', execPath: 'C:\\node\\node.exe', cli: 'fake-npm.cmd' }), {
    command: 'fake-npm.cmd',
    args: [],
  })
})

test('writes the exact verified main manifest for consumers and uses configured CLI and registry', async (t) => {
  const fixtureData = await fixture(t, [
    { code: 0, stdout: JSON.stringify({ version, optionalDependencies: { [platformPackage]: version } }) },
    { code: 0, stdout: JSON.stringify(version) },
  ])
  const manifestOutput = join(fixtureData.directory, 'main-package.json')
  const registry = 'https://registry.example.test'
  const result = spawnSync(process.execPath, [helper, version, join(fixtureData.directory, 'cache'), fixtureData.userConfig, packageName, manifestOutput], {
    encoding: 'utf8',
    env: {
      ...process.env,
      NPM_CLI: fixtureData.npm,
      NPM_TEST_FILES: `${join(fixtureData.directory, 'responses.json')}:${fixtureData.logFile}`,
      NPM_VISIBILITY_TIMEOUT_MS: '5000',
      NPM_VISIBILITY_INITIAL_BACKOFF_MS: '1',
      NPM_REGISTRY: registry,
    },
  })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(await readFile(manifestOutput, 'utf8')), {
    version,
    optionalDependencies: { [platformPackage]: version },
  })
  const calls = (await readFile(fixtureData.logFile, 'utf8')).trim().split('\n').map(JSON.parse)
  assert.equal(calls.length, 2)
  for (const args of calls) assert.equal(args[args.indexOf('--registry') + 1], registry)
})

async function fixture(t, responses) {
  const directory = await mkdtemp(join(tmpdir(), 'jsbay-npm-visibility-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const responseFile = join(directory, 'responses.json')
  const logFile = join(directory, 'calls.jsonl')
  const userConfig = join(directory, 'user.npmrc')
  await writeFile(userConfig, '')
  await writeFile(responseFile, JSON.stringify(responses))
  const npm = join(directory, 'npm')
  await writeFile(npm, `#!/usr/bin/env node
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs'
const [responseFile, logFile] = process.env.NPM_TEST_FILES.split(':')
const args = process.argv.slice(2)
appendFileSync(logFile, JSON.stringify(args) + '\\n')
const responses = JSON.parse(readFileSync(responseFile, 'utf8'))
const response = responses.shift() ?? { code: 0, stdout: JSON.stringify({ version: '${version}', optionalDependencies: { '${platformPackage}': '${version}' } }) }
writeFileSync(responseFile, JSON.stringify(responses))
process.stdout.write(response.stdout ?? '')
process.stderr.write(response.stderr ?? '')
process.exit(response.code ?? 0)
`)
  await chmod(npm, 0o755)
  return { directory, npm, logFile, userConfig }
}

function run(fixtureData, extraEnv = {}) {
  return spawnSync(process.execPath, [helper, version, join(fixtureData.directory, 'cache'), fixtureData.userConfig, packageName], {
    encoding: 'utf8',
    env: {
      ...process.env,
      NPM_CLI: fixtureData.npm,
      NPM_TEST_FILES: `${join(fixtureData.directory, 'responses.json')}:${fixtureData.logFile}`,
      NPM_TEST_MAIN_LOCATOR: `${packageName}@${version}`,
      NPM_TEST_MAIN_MANIFEST: JSON.stringify({ version, optionalDependencies: { [platformPackage]: version } }),
      NPM_VISIBILITY_TIMEOUT_MS: '5000',
      NPM_VISIBILITY_INITIAL_BACKOFF_MS: '1',
      ...extraEnv,
    },
  })
}

test('retries only exact-version ETARGET visibility and uses a fresh online cache per probe', async (t) => {
  const fixtureData = await fixture(t, [
    { code: 1, stdout: JSON.stringify({ error: { code: 'ETARGET', summary: `No matching version found for ${packageName}@${version}`, detail: `The requested resource '${packageName}@${version}' was not found.` } }) },
    { code: 1, stderr: `npm error code E404\nnpm error 404 No match found for version ${version}\nnpm error 404  The requested resource '${packageName}@${version}' could not be found.\n` },
    { code: 0, stdout: JSON.stringify({ version, optionalDependencies: { [platformPackage]: version } }) },
    { code: 0, stdout: JSON.stringify(version) },
  ])
  const result = run(fixtureData)
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, new RegExp(`${packageName}@${version} is visible`))
  assert.match(result.stderr, /ETARGET.*retry 1/s)
  assert.match(result.stderr, /E404.*retry 2/s)
  assert.match(result.stderr, /deadline/)

  const calls = (await readFile(fixtureData.logFile, 'utf8')).trim().split('\n').map(JSON.parse)
  assert.equal(calls.length, 4)
  assert.deepEqual(calls.slice(0, 3).map((args) => args[1]), Array(3).fill(`${packageName}@${version}`))
  assert.deepEqual(calls[3].slice(0, 4), ['view', `${platformPackage}@${version}`, 'version', '--json'])
  for (const args of calls) {
    assert.ok(args.includes('--prefer-online'))
    assert.ok(args.includes('--fetch-retries=0'))
  }
  const caches = calls.map((args) => args[args.indexOf('--cache') + 1])
  assert.ok(caches.every((cache) => cache === caches[0]), 'retries must refresh one isolated cache that install can reuse')
})

test('fails immediately for unrelated npm errors and for a different returned version', async (t) => {
  const network = await fixture(t, [{ code: 1, stderr: 'npm error code ECONNRESET\n' }])
  const networkResult = run(network)
  assert.notEqual(networkResult.status, 0)
  assert.match(networkResult.stderr, /ECONNRESET/)
  assert.equal((await readFile(network.logFile, 'utf8')).trim().split('\n').length, 1)

  const mismatch = await fixture(t, [{ code: 0, stdout: '"0.1.1-rc.3"' }])
  const mismatchResult = run(mismatch)
  assert.notEqual(mismatchResult.status, 0)
  assert.match(mismatchResult.stderr, /expected exact version/)
})

test('fails at the deadline when the exact package version remains unavailable', async (t) => {
  const missing = await fixture(t, Array.from({ length: 20 }, () => ({
    code: 1,
    stderr: `npm error code E404\nnpm error 404 No match found for version ${version}\nnpm error 404 The requested resource '${packageName}@${version}' could not be found.\n`,
  })))
  const result = run(missing, { NPM_VISIBILITY_TIMEOUT_MS: '1500', NPM_VISIBILITY_INITIAL_BACKOFF_MS: '5' })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /visibility deadline expired/)
  assert.ok((await readFile(missing.logFile, 'utf8')).trim().split('\n').length >= 2, 'deadline must be reached after at least one retry')
})



test('public consumer does not retry installation after the installed package fails at runtime', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'jsbay-npm-runtime-failure-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const bin = join(directory, 'bin')
  await mkdir(bin)
  const callsFile = join(directory, 'calls.jsonl')
  const downstreamFile = join(directory, 'downstream-consumer-ran')
  const fakeNpm = join(bin, 'npm')
  await writeFile(fakeNpm, `#!/usr/bin/env node
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs'
const args = process.argv.slice(2)
appendFileSync(process.env.NPM_TEST_CALLS, JSON.stringify(args) + '\\n')
if (args[0] === 'view') {
  process.stdout.write(args[1] === process.env.NPM_TEST_MAIN_LOCATOR ? process.env.NPM_TEST_MAIN_MANIFEST : JSON.stringify(process.env.NPM_TEST_VERSION))
} else if (args[0] === 'install') {
  const packageDirectory = process.cwd() + '/node_modules/@jsbay/quickjs'
  mkdirSync(packageDirectory, { recursive: true })
  const optionalDependencies = JSON.parse(process.env.NPM_TEST_MAIN_MANIFEST).optionalDependencies
  writeFileSync(packageDirectory + '/package.json', JSON.stringify({ name: '@jsbay/quickjs', version: process.env.NPM_TEST_VERSION, main: 'index.js', optionalDependencies }))
  writeFileSync(packageDirectory + '/index.js', \"throw new Error('deliberate runtime consumer failure')\\n\")
  const platformName = process.env.NPM_TEST_PLATFORM_PACKAGE
  const platformDirectory = process.cwd() + '/node_modules/@jsbay/' + platformName
  mkdirSync(platformDirectory, { recursive: true })
  writeFileSync(platformDirectory + '/package.json', JSON.stringify({ name: '@jsbay/' + platformName, version: process.env.NPM_TEST_VERSION, main: 'jsbay_node.node' }))
  writeFileSync(platformDirectory + '/jsbay_node.node', '')
  const lockPackages = {
    '': { dependencies: { '@jsbay/quickjs': process.env.NPM_TEST_VERSION } },
    'node_modules/@jsbay/quickjs': { version: process.env.NPM_TEST_VERSION, resolved: 'https://registry.npmjs.org/@jsbay/quickjs/-/quickjs.tgz', integrity: 'sha512-test', optionalDependencies },
    ['node_modules/@jsbay/' + platformName]: { version: process.env.NPM_TEST_VERSION, resolved: 'https://registry.npmjs.org/@jsbay/' + platformName + '/-/package.tgz', integrity: 'sha512-test', optional: true },
  }
  writeFileSync(process.cwd() + '/package-lock.json', JSON.stringify({ packages: lockPackages }))
} else {
  process.exit(97)
}
`)
  await chmod(fakeNpm, 0o755)
  const nodeWrapper = join(bin, 'node')
  await writeFile(nodeWrapper, `#!/bin/sh
for argument in "$@"; do
    case "$argument" in
        */package_consumer.mjs) : > "$NPM_TEST_DOWNSTREAM" ;;
    esac
done
exec "$NPM_TEST_REAL_NODE" "$@"
`)
  await chmod(nodeWrapper, 0o755)

  const platform = process.platform
  const result = spawnSync('bash', [
    join(root, 'tests/node-sdk/published-package-consumer.sh'),
    'quickjs', version, platform, process.arch,
  ], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      NPM_CLI: fakeNpm,
      NPM_TEST_CALLS: callsFile,
      NPM_TEST_DOWNSTREAM: downstreamFile,
      NPM_TEST_VERSION: version,
      NPM_TEST_MAIN_LOCATOR: `@jsbay/quickjs@${version}`,
      NPM_TEST_MAIN_MANIFEST: JSON.stringify({ version, optionalDependencies: Object.fromEntries(platformPackages.map((name) => [name, version])) }),
      NPM_TEST_PLATFORM_PACKAGE: `quickjs${platform === 'darwin' ? 'macos' : platform}${process.arch}`,
      NPM_TEST_REAL_NODE: process.execPath,
      NPM_VISIBILITY_TIMEOUT_MS: '5000',
    },
  })

  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /deliberate runtime consumer failure/)
  const calls = (await readFile(callsFile, 'utf8')).trim().split('\n').map(JSON.parse)
  assert.deepEqual(calls.map(([command]) => command), ['view', 'view', 'view', 'view', 'view', 'install'])
  assertUniformNpmOption(calls, '--cache')
  assertUniformNpmOption(calls, '--userconfig')
  assert.ok(calls.at(-1).includes('--prefer-offline'))
  await readFile(downstreamFile)
})

test('published consumer installs and resolves separated npm package names', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'jsbay-npm-separated-names-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const bin = join(directory, 'bin')
  await mkdir(bin)
  const callsFile = join(directory, 'calls.jsonl')
  const backend = 'quickjsng'
  const platform = process.platform === 'darwin' ? 'macos' : process.platform
  const platformName = `${backend}-${platform}-${process.arch}`
  const mainName = `@jsbay/${backend}`
  const platformPackage = `@jsbay/${platformName}`
  const manifest = { version, optionalDependencies: { [platformPackage]: version } }
  const fakeNpm = join(bin, 'npm')
  await writeFile(fakeNpm, `#!/usr/bin/env node
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
const args = process.argv.slice(2)
appendFileSync(process.env.NPM_TEST_CALLS, JSON.stringify(args) + '\\n')
if (args[0] === 'view') {
  process.stdout.write(args[1] === process.env.NPM_TEST_MAIN_LOCATOR ? process.env.NPM_TEST_MAIN_MANIFEST : JSON.stringify(process.env.NPM_TEST_VERSION))
} else if (args[0] === 'install') {
  const version = process.env.NPM_TEST_VERSION
  const mainName = process.env.NPM_TEST_MAIN_NAME
  const platformName = process.env.NPM_TEST_PLATFORM_NAME
  const optionalDependencies = JSON.parse(process.env.NPM_TEST_MAIN_MANIFEST).optionalDependencies
  const mainDirectory = join(process.cwd(), 'node_modules', mainName)
  const platformDirectory = join(process.cwd(), 'node_modules', platformName)
  mkdirSync(mainDirectory, { recursive: true })
  mkdirSync(platformDirectory, { recursive: true })
  writeFileSync(join(mainDirectory, 'package.json'), JSON.stringify({ name: mainName, version, main: 'index.js', optionalDependencies }))
  writeFileSync(join(mainDirectory, 'index.js'), "exports.Engine = { create: () => ({ evaluate: () => 42, close() {} }) }\\n")
  writeFileSync(join(platformDirectory, 'package.json'), JSON.stringify({ name: platformName, version, main: 'jsbay_node.node' }))
  writeFileSync(join(platformDirectory, 'jsbay_node.node'), '')
  const packages = {
    '': { dependencies: { [mainName]: version } },
    ['node_modules/' + mainName]: { version, resolved: 'https://registry.npmjs.org/' + mainName + '/-/package.tgz', integrity: 'sha512-test', optionalDependencies },
    ['node_modules/' + platformName]: { version, resolved: 'https://registry.npmjs.org/' + platformName + '/-/package.tgz', integrity: 'sha512-test', optional: true },
  }
  writeFileSync(join(process.cwd(), 'package-lock.json'), JSON.stringify({ packages }))
} else {
  process.exit(97)
}
`)
  await chmod(fakeNpm, 0o755)

  const realNode = process.execPath
  const nodeWrapper = join(bin, 'node')
  await writeFile(nodeWrapper, `#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -e && "$2" == *'const [probe, addon, backend]'* ]]; then
    test -f "$3"
    [[ "$4" == *"/node_modules/${platformPackage}/jsbay_node.node" ]]
    [[ "$5" == ${backend} ]]
    printf '%s\\n' 'mocked native backend probe resolved the separated platform package'
    exit 0
fi
exec "$NPM_TEST_REAL_NODE" "$@"
`)
  await chmod(nodeWrapper, 0o755)
  const fakeCc = join(bin, 'cc')
  await writeFile(fakeCc, `#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
    if [[ $1 == -o ]]; then : > "$2"; exit 0; fi
    shift
done
exit 2
`)
  await chmod(fakeCc, 0o755)

  const result = spawnSync('bash', [
    join(root, 'tests/node-sdk/published-package-consumer.sh'), backend, version, process.platform, process.arch,
  ], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      NPM_CLI: fakeNpm,
      NPM_TEST_CALLS: callsFile,
      NPM_TEST_MAIN_LOCATOR: `${mainName}@${version}`,
      NPM_TEST_MAIN_MANIFEST: JSON.stringify(manifest),
      NPM_TEST_MAIN_NAME: mainName,
      NPM_TEST_PLATFORM_NAME: platformPackage,
      NPM_TEST_VERSION: version,
      NPM_TEST_REAL_NODE: realNode,
      NPM_VISIBILITY_TIMEOUT_MS: '5000',
    },
  })

  assert.equal(result.status, 0, result.stderr)
  assert.ok(result.stdout.includes(`${platformPackage}@${version} from the public npm registry`))
  assert.match(result.stdout, /mocked native backend probe resolved the separated platform package/)
  const calls = (await readFile(callsFile, 'utf8')).trim().split('\n').map(JSON.parse)
  assert.deepEqual(calls.map(([command]) => command), ['view', 'view', 'install'])
  assert.ok(calls.at(-1).includes(`${mainName}@${version}`))
  assertUniformNpmOption(calls, '--cache')
  assertUniformNpmOption(calls, '--userconfig')
  assert.ok(calls.at(-1).includes('--prefer-offline'))
})

test('real npm install reuses fresh metadata for every optional platform dependency and downloads tarballs', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'jsbay-npm-cache-integration-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const tarballsDirectory = join(directory, 'tarballs')
  const consumer = join(directory, 'consumer')
  const userConfig = join(consumer, '.npmrc')
  const conflictingConfig = join(directory, 'conflicting.npmrc')
  const cache = join(directory, 'npm-cache')
  await Promise.all([mkdir(tarballsDirectory), mkdir(consumer)])

  const targets = [
    { suffix: 'macosarm64', os: 'darwin', cpu: 'arm64' },
    { suffix: 'macosx64', os: 'darwin', cpu: 'x64' },
    { suffix: 'linuxarm64', os: 'linux', cpu: 'arm64' },
    { suffix: 'linuxx64', os: 'linux', cpu: 'x64' },
  ]
  const platformPackages = targets.map(({ suffix }) => `@jsbay/quickjs${suffix}`)
  const optionalDependencies = Object.fromEntries(platformPackages.map((name) => [name, version]))
  const packageTarballs = new Map()
  for (const name of [packageName, ...platformPackages]) {
    const source = join(directory, name.replaceAll('/', '-'))
    await mkdir(source)
    const metadata = { name, version, main: 'index.js' }
    if (name === packageName) metadata.optionalDependencies = optionalDependencies
    else {
      const target = targets.find(({ suffix }) => name.endsWith(suffix))
      metadata.os = [target.os]
      metadata.cpu = [target.cpu]
    }
    await writeFile(join(source, 'package.json'), JSON.stringify(metadata))
    await writeFile(join(source, 'index.js'), `module.exports = ${JSON.stringify(name)}\n`)
    const packed = JSON.parse(execFileSync('npm', ['pack', '--json', '--pack-destination', tarballsDirectory], { cwd: source, encoding: 'utf8' }))[0]
    packageTarballs.set(name, {
      filename: packed.filename,
      contents: await readFile(join(tarballsDirectory, packed.filename)),
    })
  }

  const metadataRequests = []
  const tarballRequests = []
  const conflictingRegistryRequests = []
  let serveStaleMetadata = false
  let registryUrl
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname
    const name = decodeURIComponent(pathname.slice(1))
    if (packageTarballs.has(name)) {
      metadataRequests.push({ name, stale: serveStaleMetadata })
      const { filename, contents } = packageTarballs.get(name)
      const versions = serveStaleMetadata ? {} : {
        [version]: {
          name,
          version,
          ...(name === packageName ? { optionalDependencies } : {}),
          ...(name === packageName ? {} : {
            os: targets.find(({ suffix }) => name.endsWith(suffix)).os,
            cpu: targets.find(({ suffix }) => name.endsWith(suffix)).cpu,
          }),
          dist: {
            tarball: `${registryUrl}/tarballs/${filename}`,
            integrity: `sha512-${createHash('sha512').update(contents).digest('base64')}`,
          },
        },
      }
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'public, max-age=0' })
      response.end(JSON.stringify({ name, 'dist-tags': { latest: version }, versions }))
      return
    }
    const tarballName = pathname.slice('/tarballs/'.length)
    const tarball = [...packageTarballs.values()].find(({ filename }) => filename === tarballName)
    if (pathname.startsWith('/tarballs/') && tarball) {
      tarballRequests.push(tarballName)
      response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': tarball.contents.length })
      response.end(tarball.contents)
      return
    }
    response.writeHead(404).end()
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  t.after(() => new Promise((resolveClose) => server.close(resolveClose)))
  registryUrl = `http://127.0.0.1:${server.address().port}`
  const conflictingServer = http.createServer((request, response) => {
    conflictingRegistryRequests.push(request.url)
    response.writeHead(503).end()
  })
  conflictingServer.listen(0, '127.0.0.1')
  await once(conflictingServer, 'listening')
  t.after(() => new Promise((resolveClose) => conflictingServer.close(resolveClose)))
  const conflictingRegistry = `http://127.0.0.1:${conflictingServer.address().port}`
  await writeFile(userConfig, '')
  await writeFile(conflictingConfig, `@jsbay:registry=${conflictingRegistry}\n`)
  const noProxy = { HTTP_PROXY: '', HTTPS_PROXY: '', http_proxy: '', https_proxy: '', NO_PROXY: '127.0.0.1,localhost', no_proxy: '127.0.0.1,localhost' }
  const visibility = await execFileAsync(process.execPath, [helper, version, cache, userConfig, packageName], {
    encoding: 'utf8',
    env: {
      ...process.env,
      ...noProxy,
      NPM_CLI: 'npm',
      NPM_REGISTRY: registryUrl,
      NPM_CONFIG_USERCONFIG: conflictingConfig,
      NPM_VISIBILITY_TIMEOUT_MS: '10000',
      NPM_VISIBILITY_INITIAL_BACKOFF_MS: '5',
    },
  })
  assert.match(visibility.stdout, new RegExp(`${packageName}@${version} is visible`))
  assert.equal(metadataRequests.length, 5)
  assert.deepEqual(new Set(metadataRequests.map(({ name }) => name)), new Set([packageName, ...platformPackages]))
  assert.equal(conflictingRegistryRequests.length, 0, 'probe must ignore the conflicting ambient user config')
  assert.ok(metadataRequests.every(({ stale }) => !stale))

  serveStaleMetadata = true
  await writeFile(join(consumer, 'package.json'), JSON.stringify({ name: 'npm-cache-consumer', private: true }))
  await execFileAsync('npm', [
    'install', '--registry', registryUrl, '--userconfig', join(consumer, '.npmrc'), '--cache', cache,
    '--prefer-offline', '--fetch-retries=0', '--ignore-scripts', '--no-audit', '--no-fund', '--save-exact', `${packageName}@${version}`,
  ], { cwd: consumer, encoding: 'utf8', env: { ...process.env, ...noProxy, NPM_CONFIG_USERCONFIG: conflictingConfig } })
  assert.equal(metadataRequests.length, 5, 'install must reuse probed packuments instead of reading stale metadata')
  assert.equal(conflictingRegistryRequests.length, 0, 'install must ignore the conflicting ambient user config')
  assert.ok(tarballRequests.includes(packageTarballs.get(packageName).filename), 'npm install must download the main package tarball')
  const currentSuffix = `${process.platform === 'darwin' ? 'macos' : process.platform}${process.arch}`
  const currentPackage = `@jsbay/quickjs${currentSuffix}`
  assert.ok(tarballRequests.includes(packageTarballs.get(currentPackage).filename), 'npm install must download the current platform tarball')
  assert.equal(await readFile(join(consumer, 'node_modules', packageName, 'index.js'), 'utf8'), `module.exports = ${JSON.stringify(packageName)}\n`)
  assert.match(execFileSync(process.execPath, ['-e', `process.stdout.write(require(${JSON.stringify(join(consumer, 'node_modules', packageName))}))`], { encoding: 'utf8' }), /@jsbay\/quickjs/)
})


function assertUniformNpmOption(calls, option) {
  const values = calls.map((args) => args[args.indexOf(option) + 1])
  assert.ok(values.every(Boolean), `every npm invocation must include ${option}`)
  assert.equal(new Set(values).size, 1, `view and install must share ${option}`)
}

test('public consumer stops after a failed install even after both exact versions are visible', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'jsbay-npm-consumer-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const bin = join(directory, 'bin')
  await mkdir(bin)
  const callsFile = join(directory, 'calls.jsonl')
  const downstreamFile = join(directory, 'downstream-consumer-ran')
  const fakeNpm = join(bin, 'npm')
  await writeFile(fakeNpm, `#!/usr/bin/env node
import { appendFileSync } from 'node:fs'
const args = process.argv.slice(2)
appendFileSync(process.env.NPM_TEST_CALLS, JSON.stringify(args) + '\\n')
if (args[0] === 'view') {
  process.stdout.write(args[1] === process.env.NPM_TEST_MAIN_LOCATOR ? process.env.NPM_TEST_MAIN_MANIFEST : JSON.stringify(process.env.NPM_TEST_VERSION))
} else if (args[0] === 'install') {
  process.stderr.write('deliberate npm install failure\\n')
  process.exit(23)
} else {
  process.exit(97)
}
`)
  await chmod(fakeNpm, 0o755)
  const nodeWrapper = join(bin, 'node')
  await writeFile(nodeWrapper, `#!/bin/sh
for argument in "$@"; do
    case "$argument" in
        */package_consumer.mjs) : > "$NPM_TEST_DOWNSTREAM" ;;
    esac
done
exec "$NPM_TEST_REAL_NODE" "$@"
`)
  await chmod(nodeWrapper, 0o755)

  const backend = 'quickjs'
  const platform = process.platform
  const arch = process.arch
  const result = spawnSync('bash', [
    join(root, 'tests/node-sdk/published-package-consumer.sh'),
    backend,
    version,
    platform,
    arch,
  ], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      NPM_CLI: fakeNpm,
      NPM_TEST_CALLS: callsFile,
      NPM_TEST_DOWNSTREAM: downstreamFile,
      NPM_TEST_VERSION: version,
      NPM_TEST_MAIN_LOCATOR: `@jsbay/quickjs@${version}`,
      NPM_TEST_MAIN_MANIFEST: JSON.stringify({ version, optionalDependencies: Object.fromEntries(platformPackages.map((name) => [name, version])) }),
      NPM_TEST_REAL_NODE: process.execPath,
      NPM_VISIBILITY_TIMEOUT_MS: '5000',
    },
  })

  assert.equal(result.status, 23, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stderr, /deliberate npm install failure/)
  assert.equal(await readFile(callsFile, 'utf8').then((contents) => contents.trim().split('\n').length), 6)
  const calls = (await readFile(callsFile, 'utf8')).trim().split('\n').map(JSON.parse)
  assert.deepEqual(calls.map(([command]) => command), ['view', 'view', 'view', 'view', 'view', 'install'])
  assertUniformNpmOption(calls, '--cache')
  assertUniformNpmOption(calls, '--userconfig')
  assert.ok(calls.at(-1).includes('--prefer-offline'))
  assert.deepEqual(calls.slice(0, 5).map((args) => args[1]), [
    `@jsbay/${backend}@${version}`,
    `@jsbay/${backend}macosarm64@${version}`,
    `@jsbay/${backend}macosx64@${version}`,
    `@jsbay/${backend}linuxarm64@${version}`,
    `@jsbay/${backend}linuxx64@${version}`,

  ])
  await assert.rejects(readFile(downstreamFile), { code: 'ENOENT' })
})
