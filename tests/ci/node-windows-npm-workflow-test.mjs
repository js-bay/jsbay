import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const ci = await readFile(join(root, '.github/workflows/ci.yml'), 'utf8')
const npmWorkflow = await readFile(join(root, '.github/workflows/npm-packages.yml'), 'utf8')
const electronConsumer = await readFile(join(root, 'tests/node-sdk/electron-packaged-consumer.mjs'), 'utf8')
const reviewConsumer = await readFile(join(root, 'tests/node-sdk/review_consumer.cjs'), 'utf8')
const nodeCmake = await readFile(join(root, 'sdk/node/CMakeLists.txt'), 'utf8')
const build = await readFile(join(root, 'build.zig'), 'utf8')
const buildSupport = await readFile(join(root, 'build_support.zig'), 'utf8')
const npmConsumer = await readFile(join(root, 'tests/node-sdk/npm_package_test.mjs'), 'utf8')
const inspectorConsumer = await readFile(join(root, 'tests/node-sdk/inspector_consumer.cjs'), 'utf8')

assert.match(ci, /node-npm-version:[\s\S]*?if: github\.event_name == 'pull_request'/)
assert.match(ci, /node-npm-version:[\s\S]*?uses: actions\/setup-node@v6[\s\S]*?node-version: '24'/)
assert.match(ci, /node-npm-packages:[\s\S]*?if: github\.event_name == 'pull_request'[\s\S]*?needs: node-npm-version[\s\S]*?uses: \.\/\.github\/workflows\/npm-packages\.yml[\s\S]*?tag: \$\{\{ needs\.node-npm-version\.outputs\.tag \}\}/)
assert.match(ci, /node-npm-packages:[\s\S]*?name: Node npm platform matrix \(Windows MSVC and Electron\)/)
assert.match(npmWorkflow, /platform: win32[\s\S]*?arch: x64[\s\S]*?runner: windows-2025/)
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
assert.match(npmConsumer, /function readTarball[\s\S]*?basename\(absolute\)[\s\S]*?cwd: dirname\(absolute\)/)

const manifest = await readFile(join(root, 'build.zig.zon'), 'utf8')
const version = manifest.match(/^\s*\.version\s*=\s*"([^"\s]+)"/m)?.[1]
assert.ok(version, 'the engine manifest declares a version')
const temporary = await mkdtemp(join(tmpdir(), 'jsbay-node-windows-ci-contract-'))
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

  const source = join(temporary, 'package.tgz')
  const checksum = join(temporary, 'SHA512SUMS')
  await writeFile(source, 'package fixture')
  execFileSync(process.execPath, [join(root, 'scripts/ci/write-sha512.mjs'), source, checksum, 'package.tgz'])
  const expected = `${createHash('sha512').update('package fixture').digest('hex')}  package.tgz\n`
  assert.equal(await readFile(checksum, 'utf8'), expected)
} finally {
  await rm(temporary, { recursive: true, force: true })
}
