import assert from 'node:assert/strict'
import { chmodSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { test } from 'node:test'
import { packageTestBinaries } from '../../scripts/quality/zig-package-coverage-targets.mjs'

const packages = [
  'bytecode_cache',
  'cmph',
  'commonjs',
  'hyper_box',
  'inspector',
  'inspector_transport',
  'js_event_loop',
  'simd_utf',
  'zev',
]

function buildLog(cache, roots = packages, hashes = packages.map((_, index) => index.toString(16).padStart(32, '0'))) {
  const compilations = roots.map(name => 'info(verbose): zig test -Odebug -Mroot=libs/' + name + '/src/tests.zig --cache-dir ' + cache + ' --listen=-').join('\n')
  const executions = hashes.map(hash => 'info(verbose): ' + cache + '/o/' + hash + '/test --cache-dir=' + cache + ' --seed=0x1 --listen=-').join('\n')
  return compilations + '\n' + executions + '\n'
}

test('maps the exact package test targets in a fresh Zig cache to executable binaries', t => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-package-targets-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const cache = resolve(join(directory, 'zig-cache'))
  const hashes = packages.map((_, index) => index.toString(16).padStart(32, '0'))
  for (const hash of hashes) {
    const output = join(cache, 'o', hash)
    mkdirSync(output, { recursive: true })
    const binary = join(output, 'test')
    writeFileSync(binary, '')
    chmodSync(binary, 0o755)
  }

  assert.deepEqual(packageTestBinaries(buildLog(cache), cache), hashes.map(hash => join(cache, 'o', hash, 'test')))
})

test('rejects a missing independent package target', () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-package-targets-'))
  try {
    const cache = resolve(join(directory, 'zig-cache'))
    assert.throws(() => packageTestBinaries(buildLog(cache, packages.slice(1)), cache), /expected all 9 package test roots/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('rejects an additional package test target instead of silently changing the measured set', () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-package-targets-'))
  try {
    const cache = resolve(join(directory, 'zig-cache'))
    assert.throws(() => packageTestBinaries(buildLog(cache, packages.concat('new_package')), cache), /unexpected package test root/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('rejects a test executable outside the fresh Zig cache', () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-package-targets-'))
  try {
    const cache = resolve(join(directory, 'zig-cache'))
    const log = buildLog(cache).replace(cache + '/o/', directory + '/outside/o/')
    assert.throws(() => packageTestBinaries(log, cache), /test executable is outside the requested cache/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('rejects missing or duplicate test executable runs', () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-package-targets-'))
  try {
    const cache = resolve(join(directory, 'zig-cache'))
    const log = buildLog(cache)
    assert.throws(() => packageTestBinaries(log.replace(/info\(verbose\): .*\/test --cache-dir=.*\n?$/, ''), cache), /expected 9 distinct package test executables/)
    const duplicateLog = log.replace('/o/00000000000000000000000000000000/test --cache-dir=', '/o/00000000000000000000000000000001/test --cache-dir=')
    assert.throws(() => packageTestBinaries(duplicateLog, cache), /expected 9 distinct package test executables/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('rejects a referenced executable absent from the fresh cache', () => {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-package-targets-'))
  try {
    const cache = resolve(join(directory, 'zig-cache'))
    assert.throws(() => packageTestBinaries(buildLog(cache), cache), /package test executable is missing/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})
