import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { resolve } from 'node:path'
import { test } from 'node:test'

const script = resolve('scripts/quality/zig-libraries-coverage-report.mjs')
const packages = ['bytecode_cache', 'cmph', 'commonjs', 'hyper_box', 'inspector', 'inspector_transport', 'js_event_loop', 'simd_utf', 'zev']
const report = paths => '<coverage lines-valid="9" lines-covered="9">' + paths.map(path => '<class filename="' + path + '"><lines><line number="1" hits="1"/></lines></class>').join('') + '</coverage>'
const validate = input => spawnSync(process.execPath, [script], { input, encoding: 'utf8' })
const packageFiles = packages.map(name => name + '/src/root.zig')

test('accepts a merged report with implementation files from all nine package targets', () => {
  const result = validate(report(packageFiles))
  assert.equal(result.status, 0, result.stderr)
})

test('rejects a report missing a package target', () => {
  const result = validate(report(packageFiles.slice(1)))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /missing package coverage/)
})

test('rejects test drivers and helper files in the coverage denominator', () => {
  for (const path of ['commonjs/src/tests.zig', 'inspector/src/protocol_tests.zig', 'zev/src/tests/helpers.zig', 'inspector_transport/src/test_client.zig']) {
    const paths = packageFiles.slice()
    paths[2] = path
    const result = validate(report(paths))
    assert.notEqual(result.status, 0, path)
    assert.match(result.stderr, /test source/)
  }
})

test('rejects non-Zig code from the library coverage report', () => {
  const paths = packageFiles.slice()
  paths[0] = 'bytecode_cache/src/cache.c'
  const result = validate(report(paths))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /unsafe source path/)
})

test('rejects source paths outside the package set', () => {
  const paths = packageFiles.slice()
  paths[0] = 'src/runtime.zig'
  const result = validate(report(paths))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /outside the package set/)
})
