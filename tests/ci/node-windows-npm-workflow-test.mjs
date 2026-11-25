import { packageElectronApp } from '../node-sdk/run-electron-packager.mjs'
import { createElectronPackagerOptions, electronExecutableName } from '../node-sdk/electron-packager-options.mjs'
import { cleanupTempDirectory } from '../node-sdk/cleanup-temp-directory.mjs'
import { extractPackage } from '../node-sdk/extract-npm-package.mjs'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const ci = await readFile(join(root, '.github/workflows/ci.yml'), 'utf8')
const npmWorkflow = await readFile(join(root, '.github/workflows/npm-packages.yml'), 'utf8')
const electronConsumer = await readFile(join(root, 'tests/node-sdk/electron-packaged-consumer.mjs'), 'utf8')
const electronPackagerChild = await readFile(join(root, 'tests/node-sdk/electron-packager-child.mjs'), 'utf8')
const electronPackagerRunner = await readFile(join(root, 'tests/node-sdk/run-electron-packager.mjs'), 'utf8')
const cleanupTempDirectorySource = await readFile(join(root, 'tests/node-sdk/cleanup-temp-directory.mjs'), 'utf8')
const reviewConsumer = await readFile(join(root, 'tests/node-sdk/review_consumer.cjs'), 'utf8')
const nodeCmake = await readFile(join(root, 'sdk/node/CMakeLists.txt'), 'utf8')
const build = await readFile(join(root, 'build.zig'), 'utf8')
const buildSupport = await readFile(join(root, 'build_support.zig'), 'utf8')
const npmConsumer = await readFile(join(root, 'tests/node-sdk/npm_package_test.mjs'), 'utf8')
const inspectorConsumer = await readFile(join(root, 'tests/node-sdk/inspector_consumer.cjs'), 'utf8')
const nativeConsumerRunner = await readFile(join(root, 'tests/node-sdk/run_native_consumer.sh'), 'utf8')
const consumerWatchdog = await readFile(join(root, 'tests/node-sdk/run-consumer-with-watchdog.mjs'), 'utf8')
const nodePackageEntry = await readFile(join(root, 'sdk/node/index.cjs'), 'utf8')
const nodePackageSource = await readFile(join(root, 'sdk/node/src/jsbay_node.cpp'), 'utf8')
const jscPollingConsumer = await readFile(join(root, 'tests/node-sdk/jsc-polling-config-consumer.cjs'), 'utf8')
const jscWorkerConsumer = await readFile(join(root, 'tests/node-sdk/jsc-worker-first-load-consumer.cjs'), 'utf8')

assert.match(ci, /node-npm-version:[\s\S]*?if: github\.event_name == 'pull_request'/)
assert.match(ci, /node-npm-version:[\s\S]*?uses: actions\/setup-node@v6[\s\S]*?node-version: '24'/)
assert.match(ci, /node-npm-packages:[\s\S]*?if: github\.event_name == 'pull_request'[\s\S]*?needs: node-npm-version[\s\S]*?uses: \.\/\.github\/workflows\/npm-packages\.yml[\s\S]*?tag: \$\{\{ needs\.node-npm-version\.outputs\.tag \}\}/)
assert.match(ci, /node-npm-packages:[\s\S]*?name: Node npm platform matrix \(Windows MSVC and Electron\)/)
assert.match(npmWorkflow, /platform: win32[\s\S]*?arch: x64[\s\S]*?runner: windows-2025/)
assert.equal([...nativeConsumerRunner.matchAll(/run-consumer-with-watchdog\.mjs"\s+30000[^\n]*extended_contract_consumer\.cjs/g)].length, 2, 'both extended contract consumers run under the external watchdog')
assert.match(nativeConsumerRunner, /JSBAY_NODE_BACKEND:-\} == jsc && \${JSBAY_NODE_PLATFORM:-\} == darwin && \${JSBAY_NODE_ARCH:-\} == arm64/)
assert.match(nativeConsumerRunner, /env JSC_usePollingTraps=true[\s\S]*?diagnostic retry passed[\s\S]*?preserving first failure/)
assert.match(nativeConsumerRunner, /run_jsc_arm64_public_entry_contracts\n/)
assert.match(nativeConsumerRunner, /JSC package entry enables polling by default' env -u JSC_usePollingTraps/)
assert.match(nativeConsumerRunner, /preserves explicit polling opt-in[\s\S]*?JSC_usePollingTraps=1/)
assert.match(nativeConsumerRunner, /rejects explicit polling opt-out[\s\S]*?JSC_usePollingTraps=false/)
assert.match(nativeConsumerRunner, /Worker first addon load can interrupt execution[\s\S]*?jsc-worker-first-load-consumer\.cjs/)
assert.match(nodePackageEntry, /backend === 'jsc'[\s\S]*?process\.arch === 'arm64'[\s\S]*?JSC_usePollingTraps === undefined[\s\S]*?process\.env\.JSC_usePollingTraps = 'true'/)
assert.match(nodePackageSource, /configureJscPollingTraps\(napi_env env\)[\s\S]*?setenv\("JSC_usePollingTraps", "true", 0\)/)
assert.match(nodePackageSource, /JSC_usePollingTraps=true before the first JavaScriptCore VM is created/)
assert.match(jscPollingConsumer, /capabilities\.executionLimit, enabled/)
assert.match(jscPollingConsumer, /capabilities\.flags & \(1 << 2\)/)
assert.match(jscWorkerConsumer, /process\.env\.JSC_usePollingTraps, undefined/)
assert.match(jscWorkerConsumer, /new Worker\(/)
assert.match(jscWorkerConsumer, /require\(entry\)/)
assert.match(npmWorkflow, /name: Test the release addon[\s\S]*?JSBAY_NODE_BACKEND: \$\{\{ matrix\.backend \}\}[\s\S]*?JSBAY_NODE_PLATFORM: \$\{\{ matrix\.platform \}\}[\s\S]*?JSBAY_NODE_ARCH: \$\{\{ matrix\.arch \}\}/)
assert.match(consumerWatchdog, /spawn\(command, args[\s\S]*?process\.exitCode = code/)
assert.match(consumerWatchdog, /spawn\('sample',[\s\S]*?String\(consumer\.pid\)/)
assert.match(consumerWatchdog, /sampler\.kill\('SIGKILL'\)[\s\S]*?consumer\.kill\('SIGKILL'\)[\s\S]*?process\.exit\(1\)/)
const releaseAddonStep = npmWorkflow.match(/      - name: Test the release addon[\s\S]*?(?=\n      - name:|\n  collect-packages:)/)?.[0]
assert.ok(releaseAddonStep, 'the release addon consumer step exists')
assert.match(releaseAddonStep, /^        timeout-minutes: 15$/m, 'the release addon consumer step has a finite hard timeout')
assert.equal(
  [...npmWorkflow.matchAll(/^\s+JSBAY_NPM_PLATFORM:\s+\$\{\{\s*matrix\.platform\s*\}\}\s*$/gm)].length,
  3,
  'each npm step that needs the platform uses the collision-safe environment name',
)
assert.doesNotMatch(npmWorkflow, /^\s+PLATFORM:/m, 'Windows toolchains may export Platform with different capitalization')
assert.doesNotMatch(npmWorkflow, /\$PLATFORM\b/, 'shell steps must not read the colliding PLATFORM name')
assert.match(npmWorkflow, /node tests\/node-sdk\/npm_package_test\.mjs/)
assert.match(npmWorkflow, /JSBAY_NODE_ADDON=\"\$JSBAY_NODE_ADDON\" node tests\/node-sdk\/inspector_consumer\.cjs/)
assert.doesNotMatch(npmWorkflow, /inspector-transport=false/, 'Windows npm build includes the bundled Inspector transport')
assert.match(npmWorkflow, /node --expose-gc tests\/node-sdk\/review_consumer\.cjs close-async-contract/)
assert.match(npmWorkflow, /node --expose-gc tests\/node-sdk\/review_consumer\.cjs worker-close-async-gc/)
assert.match(npmWorkflow, /node --expose-gc tests\/node-sdk\/review_consumer\.cjs pending-engine-gc/)
assert.match(npmWorkflow, /node tests\/node-sdk\/electron-packaged-consumer\.mjs/)
assert.doesNotMatch(npmWorkflow, /tar\s+-xzf\s+"\$headers"/, 'Windows tar must not interpret a drive letter as a remote host')
assert.match(npmWorkflow, /electron_version="\$\(node tests\/node-sdk\/electron-packaged-consumer\.mjs --print-version\)"/)
assert.doesNotMatch(npmWorkflow, /shasum -a 512/)
assert.match(npmWorkflow, /write-sha512\.mjs/)
assert.match(electronConsumer, /const electronVersion = '([^']+)'/)
assert.equal([...electronConsumer.matchAll(/const electronVersion = /g)].length, 1)
assert.match(electronConsumer, /args\[0\] === '--print-version'/)
assert.match(electronConsumer, /--js-flags=--expose-gc/)
assert.match(electronConsumer, /closeAsync\(/)
assert.match(electronConsumer, /new Worker\(/)
assert.match(electronConsumer, /global\.gc\(/)
assert.match(electronConsumer, /postMessage\('closed'\)/)
assert.match(reviewConsumer, /async function closeAsyncContract\(/)
assert.match(reviewConsumer, /function workerCloseAsyncGc\(/)
assert.match(reviewConsumer, /async function pendingEngineGc\(/)
assert.match(nodeCmake, /jsbay\.lib on Windows, libjsbay\.a on Unix-like systems/)
assert.match(build, /build_support\.linkMathLibrary\(lib_module, os\)/)
assert.match(buildSupport, /pub fn linkMathLibrary[\s\S]*?if \(os == \.windows\) return;[\s\S]*?linkSystemLibrary\(\"m\"/, 'the core library skips libm on Windows')
assert.ok(build.includes('if (!shared and (os.isDarwin() or (os == .linux and !target.result.abi.isAndroid() and !ohos) or os == .windows))\n        lib.bundle_compiler_rt = true;'), 'the static Windows library bundles Zig compiler-rt')
assert.ok(nodeCmake.includes('target_link_libraries(jsbay_node PRIVATE ${NODE_LIBRARY} delayimp ws2_32 ntdll)'), 'Windows Node addons link ntdll for Zig runtime imports')
assert.ok(nodeCmake.includes('target_link_libraries(jsbay_node PRIVATE ${NODE_LIBRARY} delayimp ws2_32 ntdll)'), 'Windows Node addons link Winsock for the bundled Inspector transport')
assert.match(nodeCmake, /if\(WIN32\)[\s\S]*?target_compile_definitions\(jsbay_node PRIVATE NOMINMAX\)/, 'the Windows addon disables the max macro from its dependencies')
assert.match(inspectorConsumer, /inspectorStart\(0\)/)
assert.match(inspectorConsumer, /127\.0\.0\.1/)
assert.match(inspectorConsumer, /webSocketDebuggerUrl/)
assert.match(inspectorConsumer, /new WebSocket\(/)
assert.match(inspectorConsumer, /Runtime\.enable/)
assert.match(inspectorConsumer, /Runtime\.evaluate/)
assert.match(inspectorConsumer, /inspectorStop\(/)
assert.match(electronConsumer, /extractPackage\(tarballs\[0\]/)
assert.match(electronConsumer, /packageElectronApp\(/)
assert.doesNotMatch(electronConsumer, /await import\(pathToFileURL/, 'the parent process does not import Electron Packager')
assert.match(electronPackagerRunner, /runCommand\(process\.execPath/)
assert.match(electronPackagerRunner, /electron-packager-child\.mjs/)
assert.match(electronPackagerChild, /await import\(packagerUrl\)/)
const electronPackagerOptions = createElectronPackagerOptions('app-directory', 'output-directory', '44.11.5')
assert.equal(electronPackagerOptions.name, electronExecutableName, 'the packaged directory name comes from the explicit Packager name option')
assert.equal(electronPackagerOptions.executableName, electronExecutableName, 'the Windows executable name comes from the explicit Packager executableName option')
assert.equal(electronPackagerOptions.platform, 'win32')
assert.equal(electronPackagerOptions.arch, 'x64')
assert.match(electronConsumer, /join\(appPath, `\$\{electronExecutableName\}\.exe`\)/, 'the smoke process uses the exact configured executable name')
assert.doesNotMatch(electronPackagerChild, /appName:/, 'Electron Packager receives its documented name option')
assert.match(cleanupTempDirectorySource, /if \(!operationError\) throw cleanupError/)
assert.doesNotMatch(electronConsumer, /tar['"],[\s\S]*?-C['"],[\s\S]*?destination/, 'tar must not receive an absolute Windows destination argument')
assert.match(npmConsumer, /function readTarball[\s\S]*?basename\(absolute\)[\s\S]*?cwd: dirname\(absolute\)/)

const manifest = await readFile(join(root, 'build.zig.zon'), 'utf8')
const version = manifest.match(/^\s*\.version\s*=\s*"([^"\s]+)"/m)?.[1]
assert.ok(version, 'the engine manifest declares a version')
const temporary = await mkdtemp(join(tmpdir(), 'jsbay-node-windows-ci-contract-'))
const watchdogPath = join(root, 'tests/node-sdk/run-consumer-with-watchdog.mjs')
const exitStatus = spawnSync(process.execPath, [watchdogPath, '30000', process.execPath, '-e', 'process.exit(7)'], { encoding: 'utf8' })
assert.equal(exitStatus.status, 7, 'the watchdog preserves a completed consumer exit code')
const timeoutStatus = spawnSync(process.execPath, [watchdogPath, '100', process.execPath, '-e', 'setInterval(() => {}, 1000)'], { encoding: 'utf8', timeout: 10000 })
assert.equal(timeoutStatus.status, 1, 'the watchdog reports a timeout as failure')
assert.match(timeoutStatus.stderr, /consumer exceeded its 100ms watchdog/)
try {
  const output = join(temporary, 'github-output')
  execFileSync(process.execPath, [join(root, 'scripts/ci/resolve-npm-ci-tag.mjs')], {
    cwd: root,
    env: { ...process.env, GITHUB_OUTPUT: output },
  })
  assert.equal(await readFile(output, 'utf8'), `tag=v${version}\n`)

  const electronVersion = execFileSync(process.execPath, [join(root, 'tests/node-sdk/electron-packaged-consumer.mjs'), '--print-version'], {
    cwd: root,
    encoding: 'utf8',
  }).trim()
  assert.equal(electronVersion, electronConsumer.match(/const electronVersion = '([^']+)'/)?.[1])

  const workerSourceLiteral = electronConsumer.match(/^const electronWorkerSource = ("(?:[^"\\]|\\.)*")$/m)?.[1]
  assert.ok(workerSourceLiteral, 'Electron worker source is available for syntax validation')
  const workerSource = JSON.parse(workerSourceLiteral)
  const appSourceExpression = electronConsumer.match(/await writeFile\(join\(appDir, 'main\.cjs'\), (\[[\s\S]*?\]\.join\('\\n'\))\)/)?.[1]
  assert.ok(appSourceExpression, 'packaged Electron app source is defined in one expression')
  const appSource = new Function('electronWorkerSource', `return ${appSourceExpression}`)(workerSource)
  const appFile = join(temporary, 'electron-main.cjs')
  await writeFile(appFile, appSource)
  execFileSync(process.execPath, ['--check', appFile])

  const fakePackager = join(temporary, 'fake-packager.mjs')
  await writeFile(fakePackager, "export async function packager(options) { return [{ path: options.out, pid: process.pid }] }\n")
  const isolatedBundles = await packageElectronApp(fakePackager, temporary, join(temporary, 'packaged'), '44.11.5')
  assert.equal(isolatedBundles.length, 1)
  assert.notEqual(isolatedBundles[0].pid, process.pid, 'Electron Packager module executes in a child Node process')

  const failingPackager = join(temporary, 'failing-packager.mjs')
  await writeFile(failingPackager, "export async function packager() { throw new Error('mock packager failure') }\n")
  await assert.rejects(packageElectronApp(failingPackager, temporary, join(temporary, 'failed-output'), '44.11.5'), /mock packager failure/)

  const operationError = new Error('primary packaging failure')
  const cleanupError = new Error('cleanup failure')
  const cleanupReports = []
  await assert.rejects((async () => {
    let failure
    try { throw operationError } catch (error) { failure = error; throw error }
    finally {
      await cleanupTempDirectory('temporary-directory', failure, async () => { throw cleanupError }, message => cleanupReports.push(message))
    }
  })(), error => error === operationError)
  assert.match(cleanupReports[0], /cleanup failure/)
  await assert.rejects(cleanupTempDirectory('temporary-directory', undefined, async () => { throw cleanupError }, () => {}), error => error === cleanupError)

  const archiveFixture = join(temporary, 'npm-package.tgz')
  await writeFile(archiveFixture, 'archive fixture')
  const extractedDirectory = join(temporary, 'extracted-package')
  let tarInvocation
  const packageManifest = await extractPackage(archiveFixture, extractedDirectory, async (command, args, options) => {
    tarInvocation = { command, args, options }
    assert.equal(await readFile(join(options.cwd, '.jsbay-package.tgz'), 'utf8'), 'archive fixture')
    await writeFile(join(options.cwd, 'package.json'), JSON.stringify({ name: 'package fixture' }))
  })
  assert.deepEqual(packageManifest, { name: 'package fixture' })
  assert.equal(tarInvocation.command, 'tar')
  assert.deepEqual(tarInvocation.args, ['-xzf', '.jsbay-package.tgz', '--strip-components=1'])
  assert.equal(tarInvocation.options.cwd, extractedDirectory)
  assert.ok(tarInvocation.args.every(argument => !/^[A-Za-z]:[\\/]/.test(argument)), 'tar receives no Windows drive-qualified arguments')
  assert.equal(existsSync(join(extractedDirectory, '.jsbay-package.tgz')), false, 'the staged archive is removed after extraction')

  const archiveRoot = join(temporary, 'archive-root')
  await mkdir(join(archiveRoot, 'package'), { recursive: true })
  await writeFile(join(archiveRoot, 'package', 'package.json'), JSON.stringify({ name: 'default runner package' }))
  const defaultArchive = join(temporary, 'default-runner.tgz')
  execFileSync('tar', ['-czf', defaultArchive, '-C', archiveRoot, 'package'])
  const defaultDestination = join(temporary, 'default-runner-package')
  const defaultManifest = await extractPackage(defaultArchive, defaultDestination)
  assert.deepEqual(defaultManifest, { name: 'default runner package' }, 'production-style two-argument extraction invokes real tar')
  assert.equal(existsSync(join(defaultDestination, '.jsbay-package.tgz')), false, 'the default runner also cleans up the staged archive')

  const failedDirectory = join(temporary, 'failed-package')
  await assert.rejects(extractPackage(archiveFixture, failedDirectory, async () => { throw new Error('mock tar failure') }), /mock tar failure/)
  assert.equal(existsSync(join(failedDirectory, '.jsbay-package.tgz')), false, 'the staged archive is removed after extraction failure')

  const source = join(temporary, 'package.tgz')
  const checksum = join(temporary, 'SHA512SUMS')
  await writeFile(source, 'package fixture')
  execFileSync(process.execPath, [join(root, 'scripts/ci/write-sha512.mjs'), source, checksum, 'package.tgz'])
  const expected = `${createHash('sha512').update('package fixture').digest('hex')}  package.tgz\n`
  assert.equal(await readFile(checksum, 'utf8'), expected)
} finally {
  await rm(temporary, { recursive: true, force: true })
}
