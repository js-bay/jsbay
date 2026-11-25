import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { resolve } from 'node:path'
import { test } from 'node:test'

const script = resolve('scripts/quality/zig-coverage-summary.mjs')
const parse = input => spawnSync(process.execPath, [script], { input, encoding: 'utf8' })
const parseStrict = input => spawnSync(process.execPath, [script, '--no-skips'], { input, encoding: 'utf8' })

test('reports passing and skipped tests from a complete Zig run', () => {
  const result = parse('1/2 example...OK\n2/2 example...SKIP\n1 passed; 1 skipped; 0 failed.\n')
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), { passed: 1, skipped: 1, failed: 0 })
})

test('accepts a complete run with no skipped tests', () => {
  const result = parse('All 3 tests passed.\n')
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), { passed: 3, skipped: 0, failed: 0 })
})

test('rejects a failed run even when the coverage tool exits successfully', () => {
  assert.notEqual(parse('1 passed; 0 skipped; 1 failed.\n').status, 0)
})

test('rejects missing, empty, incomplete, or panicked test results', () => {
  for (const input of [
    '',
    'All 0 tests passed.\n',
    '1/3 example...OK\n',
    'thread 1 panic: unrecognized command line argument\n',
  ]) {
    assert.notEqual(parse(input).status, 0)
  }
})

test('strict package mode accepts only a complete, fully listed, zero-skip run', () => {
  const result = parseStrict('1/2 first test...OK\n2/2 second test...\nchild diagnostic output\nOK\nAll 2 tests passed.\n')
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), { passed: 2, skipped: 0, failed: 0 })
})

test('strict package mode rejects child panic, explicit failure, skips, and incomplete output even with kcov-style success', () => {
  const invalidLogs = [
    'thread 123 panic: child crashed\nAll 1 test passed.\n',
    '1/1 test...FAIL\nAll 1 tests passed.\n',
    '1/2 first test...OK\n2/2 second test...SKIP\n1 passed; 0 skipped; 0 failed.\n',
    '1/2 first test...OK\nAll 2 tests passed.\n',
    '1/1 test...OK\n',
  ]
  for (const input of invalidLogs) assert.notEqual(parseStrict(input).status, 0, input)
})
