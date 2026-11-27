import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const checker = join(root, 'tests/android-sdk/check-maven-capability-conflict.mjs')
const temp = await mkdtemp(join(tmpdir(), 'jsbay-maven-capability-conflict-'))
const newer = 'jsbay-quickjs'
const legacy = 'jsbayquickjs'
const version = '0.1.2'
const valid = `Could not resolve io.jsbay:${newer}:${version}.\n` +
  `      Cannot select module with conflict on capability 'io.jsbay:${legacy}:${version}' also provided by [io.jsbay:${legacy}:${version}(runtime)]\n` +
  `Could not resolve io.jsbay:${legacy}:${version}.\n` +
  `      Cannot select module with conflict on capability 'io.jsbay:${legacy}:${version}' also provided by [io.jsbay:${newer}:${version}(releaseVariantReleaseRuntimePublication)]\n`

async function check(name, contents) {
  const log = join(temp, `${name}.log`)
  await writeFile(log, contents)
  return spawnSync(process.execPath, [checker, log, newer, legacy, version], { encoding: 'utf8' })
}

try {
  const accepted = await check('valid', valid)
  assert.equal(accepted.status, 0, accepted.stderr)

  for (const [name, contents] of [
    ['unrelated', `Could not resolve io.jsbay:${newer}:${version}.\nCould not resolve io.jsbay:${legacy}:${version}.\nCould not resolve org.example:missing:1.0.\n`],
    ['wrong-capability', valid.replaceAll(`io.jsbay:${legacy}:${version}'`, `io.jsbay:other:${version}'`)],
    ['wrong-coordinate', valid.replace(`io.jsbay:${newer}:${version}(releaseVariantReleaseRuntimePublication)`, `io.jsbay:other:${version}(releaseVariantReleaseRuntimePublication)`)],
    ['single-coordinate', valid.replace(`Could not resolve io.jsbay:${legacy}:${version}.\n`, '')],
  ]) {
    const rejected = await check(name, contents)
    assert.notEqual(rejected.status, 0, `${name} failure must not be accepted as a capability conflict`)
  }
} finally {
  await rm(temp, { recursive: true, force: true })
}
