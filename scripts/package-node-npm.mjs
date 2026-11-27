import { cp, mkdir, readFile, writeFile } from 'node:fs/promises'
import { basename, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const root = resolve(fileURLToPath(new URL('..', import.meta.url)))
const [mode, backend, version, ...arguments_] = process.argv.slice(2)
const [platform, arch, addonPath] = mode === 'platform' ? arguments_ : []
const outputPath = mode === 'main' ? arguments_[0] : arguments_[3]
const backends = new Set(['quickjs', 'quickjsng', 'jsc'])
const packageTargets = {
  'darwin-arm64': ['macos', 'arm64'],
  'darwin-x64': ['macos', 'x64'],
  'linux-arm64': ['linux', 'arm64'],
  'linux-x64': ['linux', 'x64'],
  'win32-x64': ['win32', 'x64'],
}
const macosMinimum = '11.0'

function compareVersions(left, right) {
  const leftParts = left.split('.').map(Number)
  const rightParts = right.split('.').map(Number)
  for (let index = 0; index < 3; index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0)
    if (difference !== 0) return difference
  }
  return 0
}

function macosDeploymentVersion(addon) {
  const commands = execFileSync('otool', ['-l', addon], { encoding: 'utf8' }).split(/(?=Load command \d+)/)
  const versions = []
  for (const command of commands) {
    if (command.includes('cmd LC_BUILD_VERSION') && /platform\s+1\b/.test(command)) {
      const version = command.match(/minos\s+([0-9.]+)/)?.[1]
      if (version) versions.push(version)
    } else if (command.includes('cmd LC_VERSION_MIN_MACOSX')) {
      const version = command.match(/version\s+([0-9.]+)/)?.[1]
      if (version) versions.push(version)
    }
  }
  if (versions.length === 0) throw new Error(`Could not determine the macOS deployment target for ${addon}`)
  const minimum = versions.sort(compareVersions).at(-1)
  if (compareVersions(minimum, macosMinimum) > 0) {
    throw new Error(`Addon requires macOS ${minimum}, above the supported minimum ${macosMinimum}`)
  }
  return minimum
}

if (!backends.has(backend) || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version) || !['main', 'platform'].includes(mode) || !outputPath) {
  throw new Error('Usage: package-node-npm.mjs <main|platform> <quickjs|quickjsng|jsc> <version> [<darwin|linux> <arm64|x64> <addon.node>] <output-dir>')
}

const output = resolve(outputPath)
const mainDir = join(output, backend)
const sourcePackage = JSON.parse(await readFile(join(root, 'sdk/node/package.json'), 'utf8'))
const packageName = `@jsbay/${backend}`
const repository = { type: 'git', url: 'https://github.com/js-bay/jsbay.git', directory: 'sdk/node' }

if (mode === 'main') {
  await mkdir(mainDir, { recursive: true })
  await cp(join(root, 'sdk/node/index.cjs'), join(mainDir, 'index.cjs'))
  await cp(join(root, 'sdk/node/index.d.ts'), join(mainDir, 'index.d.ts'))
  await cp(join(root, 'sdk/node/README.md'), join(mainDir, 'README.md'))
  await cp(join(root, 'LICENSE'), join(mainDir, 'LICENSE'))
  await cp(join(root, 'THIRD_PARTY_NOTICES.md'), join(mainDir, 'THIRD_PARTY_NOTICES.md'))
  const supportedTargets = backend === 'jsc'
    ? [['macos', 'arm64'], ['macos', 'x64']]
    : [['macos', 'arm64'], ['macos', 'x64'], ['linux', 'arm64'], ['linux', 'x64'], ...(backend === 'quickjsng' ? [['win32', 'x64']] : [])]
  const optionalDependencies = Object.fromEntries(supportedTargets.map(([os, cpu]) => {
    const name = `${backend}-${os}-${cpu}`
    return [`@jsbay/${name}`, version]
  }))
  await writeFile(join(mainDir, 'package.json'), `${JSON.stringify({
    name: packageName,
    version,
    description: `JsBay Node.js SDK using the ${backend} engine`,
    type: sourcePackage.type,
    main: sourcePackage.main,
    types: sourcePackage.types,
    exports: sourcePackage.exports,
    license: 'MIT',
    repository,
    jsbayBackend: backend,
    optionalDependencies,
  }, null, 2)}\n`)
  console.log(`Prepared ${packageName}@${version}`)
} else {
  const target = packageTargets[`${platform}-${arch}`]
  if (!target || !addonPath || (backend === 'jsc' && platform !== 'darwin') || (platform === 'win32' && backend !== 'quickjsng')) throw new Error('Unsupported native addon target')
  const [npmPlatform, npmArch] = target
  const platformName = `${backend}-${npmPlatform}-${npmArch}`
  const platformPackageName = `@jsbay/${platformName}`
  const binaryDir = join(output, platformName)
  await mkdir(binaryDir, { recursive: true })
  await cp(addonPath, join(binaryDir, 'jsbay_node.node'))
  await cp(join(root, 'LICENSE'), join(binaryDir, 'LICENSE'))
  await cp(join(root, 'THIRD_PARTY_NOTICES.md'), join(binaryDir, 'THIRD_PARTY_NOTICES.md'))
  let jsbayGlibcMinimum
  let jsbayMacosMinimum
  if (platform === 'linux') {
    const versions = execFileSync('readelf', ['--version-info', addonPath], { encoding: 'utf8' })
      .match(/GLIBC_(\d+\.\d+)/g)
      ?.map((value) => value.slice('GLIBC_'.length)) ?? []
    if (versions.length === 0) throw new Error('Could not determine the addon GLIBC symbol baseline')
    jsbayGlibcMinimum = versions.sort((left, right) => {
      const [leftMajor, leftMinor] = left.split('.').map(Number)
      const [rightMajor, rightMinor] = right.split('.').map(Number)
      return leftMajor - rightMajor || leftMinor - rightMinor
    }).at(-1)
  } else if (platform === 'darwin') {
    jsbayMacosMinimum = macosDeploymentVersion(addonPath)
  }
  await writeFile(join(binaryDir, 'package.json'), `${JSON.stringify({
    name: platformPackageName,
    version,
    description: `JsBay Node.js native addon for ${backend} on ${npmPlatform}-${npmArch}`,
    os: [platform],
    cpu: [arch],
    ...(platform === 'linux' ? { libc: 'glibc', jsbayGlibcMinimum } : platform === 'darwin' ? { jsbayMacosMinimum } : {}),
    main: 'jsbay_node.node',
    files: ['jsbay_node.node', 'LICENSE', 'THIRD_PARTY_NOTICES.md'],
    license: 'MIT',
    repository,
  }, null, 2)}\n`)
  const libc = jsbayGlibcMinimum ? ` (glibc ${jsbayGlibcMinimum} or newer)` : ''
  console.log(`Prepared ${platformPackageName}@${version} from ${basename(addonPath)}${libc}`)
}
