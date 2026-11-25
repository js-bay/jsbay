import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const dir = mkdtempSync(join(tmpdir(), 'jsbay-package-names-'))
try {
  for (const backend of ['quickjs', 'quickjsng', 'jsc']) {
    execFileSync(process.execPath, ['scripts/package-node-npm.mjs', 'main', backend, '0.0.0', dir])
    const manifest = JSON.parse(readFileSync(join(dir, backend, 'package.json')))
    const platforms = backend === 'jsc' ? ['macos-arm64', 'macos-x64'] : ['macos-arm64', 'macos-x64', 'linux-arm64', 'linux-x64']
    if (backend === 'quickjsng') platforms.push('win32-x64')
    assert.deepEqual(Object.keys(manifest.optionalDependencies).sort(), platforms.map(platform => `@jsbay/${backend}-${platform}`).sort())
  }
  console.log('npm platform package names passed')
} finally {
  rmSync(dir, { recursive: true, force: true })
}
