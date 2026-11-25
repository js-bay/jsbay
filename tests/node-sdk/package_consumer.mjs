import assert from 'node:assert/strict'
import { createRequire } from 'node:module'

const require = createRequire(process.env.JSBAY_NODE_PACKAGE_ROOT || import.meta.url)
const name = process.env.JSBAY_NODE_PACKAGE || '@jsbay/quickjsng'
const publicVersion = process.env.JSBAY_NODE_PUBLIC_VERSION
if (publicVersion) {
  const platform = process.platform === 'darwin' ? 'macos' : process.platform
  const { packages } = require('./package-lock.json')
  const installedMain = packages[`node_modules/${name}`]
  const platformCandidates = [
    `${name}-${platform}-${process.arch}`,
    `${name}${platform}${process.arch}`,
  ]
  const platformPackage = platformCandidates.find(candidate =>
    Object.hasOwn(installedMain?.optionalDependencies ?? {}, candidate))
  assert(platformPackage, `The installed ${name} package does not declare a ${platform}-${process.arch} addon`)
  assert.deepEqual(packages[''].dependencies, { [name]: publicVersion })
  for (const dependency of [name, platformPackage]) {
    const locked = packages[`node_modules/${dependency}`]
    assert.equal(locked?.version, publicVersion, `npm must install ${dependency}@${publicVersion}`)
    assert.equal(new URL(locked.resolved).origin, 'https://registry.npmjs.org')
    assert.match(locked.integrity, /^sha512-/)
  }
  assert.equal(packages[`node_modules/${platformPackage}`].optional, true)
  assert.match(require.resolve(platformPackage), /[/\\]jsbay_node\.node$/)
  console.log(`Resolved ${platformPackage}@${publicVersion} from the public npm registry`)
}
const addon = require(name)

assert.equal(typeof addon.Engine.create, 'function')
const engine = addon.Engine.create({ instanceId: 4381 })
try {
  assert.equal(engine.evaluate('6 * 7', 'package.mjs'), 42)
} finally {
  engine.close()
}

console.log('node SDK package consumer passed')
