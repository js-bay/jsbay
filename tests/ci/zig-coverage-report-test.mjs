import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { resolve } from 'node:path'
import { test } from 'node:test'

const script = resolve('scripts/quality/zig-coverage-report.mjs')
const validate = input => spawnSync(process.execPath, [script], { input, encoding: 'utf8' })

test('rejects an empty Cobertura report', () => {
  const result = validate('<?xml version="1.0"?><coverage lines-valid="0"><packages/></coverage>')
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /positive lines-valid/)
})

test('accepts a Cobertura report with covered lines and a Zig class', () => {
  const result = validate(`<?xml version="1.0"?><!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-04.dtd'><coverage lines-valid="12"><packages><package><classes><class filename="src/runtime.zig"/></classes></package></packages></coverage>`)
  assert.equal(result.status, 0, result.stderr)
})
