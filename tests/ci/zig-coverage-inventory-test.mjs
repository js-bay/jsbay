import assert from 'node:assert/strict'
import { test } from 'node:test'
import { buildCoverageInventory } from '../../scripts/quality/zig-coverage-inventory.mjs'

const cobertura = (...filenames) => `<coverage>${filenames.map(filename => `<class filename="${filename}"><lines><line number="1" hits="1"/></lines></class>`).join('')}</coverage>`

test('maps report paths only through their explicit source roots', () => {
  const result = buildCoverageInventory([
    'src/shared.zig',
    'libs/shared.zig',
    'libs/commonjs/src/root.zig',
    'build.zig',
  ], [
    { scope: 'src', xml: cobertura('shared.zig') },
    { scope: 'libs', xml: cobertura('shared.zig', 'commonjs/src/root.zig') },
  ])

  assert.deepEqual(result.scopes.src.reportedFiles, ['src/shared.zig'])
  assert.deepEqual(result.scopes.libs.reportedFiles, ['libs/commonjs/src/root.zig', 'libs/shared.zig'])
  assert.equal(result.scopes.src.files[0].status, 'reported')
  assert.deepEqual(result.scopes.root.unreportedFiles, ['build.zig'])
})

test('records non-Zig report classes outside the requested coverage inventory', () => {
  const result = buildCoverageInventory(['src/runtime.zig'], [
    { scope: 'src', xml: cobertura('runtime.zig', 'runtime.c') },
  ])

  assert.deepEqual(result.scopes.src.ignoredNonZigReportPaths, ['runtime.c'])
  assert.deepEqual(result.scopes.src.reportedFiles, ['src/runtime.zig'])
})

test('classifies test files and test paths without treating them as covered product files', () => {
  const result = buildCoverageInventory([
    'src/runtime.zig',
    'src/uncovered.zig',
    'src/tests/engine.zig',
    'libs/commonjs/src/root_tests.zig',
    'tools/test.zig',
  ], [
    { scope: 'src', xml: cobertura('runtime.zig') },
  ])

  assert.deepEqual(result.testFiles, [
    'libs/commonjs/src/root_tests.zig',
    'src/tests/engine.zig',
    'tools/test.zig',
  ])
  assert.deepEqual(result.scopes.src.unreportedFiles, ['src/tests/engine.zig', 'src/uncovered.zig'])
  assert.deepEqual(result.scopes.src.unreportedImplementationFiles, ['src/uncovered.zig'])
  assert.deepEqual(result.scopes.src.unreportedTestFiles, ['src/tests/engine.zig'])
  assert.deepEqual(result.scopes.libs.unreportedFiles, ['libs/commonjs/src/root_tests.zig'])
  assert.deepEqual(result.scopes.libs.unreportedImplementationFiles, [])
  assert.deepEqual(result.scopes.libs.unreportedTestFiles, ['libs/commonjs/src/root_tests.zig'])
})

test('keeps file category separate from whether its path appears in a report', () => {
  const result = buildCoverageInventory(['src/tests/engine.zig'], [
    { scope: 'src', xml: cobertura('tests/engine.zig') },
  ])

  assert.deepEqual(result.scopes.src.reportedFiles, ['src/tests/engine.zig'])
  assert.deepEqual(result.scopes.src.unreportedTestFiles, [])
  assert.deepEqual(result.scopes.src.files, [{
    path: 'src/tests/engine.zig',
    category: 'test',
    status: 'reported',
  }])
})

test('rejects a report path that does not match a tracked Zig source', () => {
  assert.throws(() => buildCoverageInventory(['src/runtime.zig'], [
    { scope: 'src', xml: cobertura('generated.zig') },
  ]), /not a tracked Zig source/)
})

test('rejects duplicate tracked Zig paths instead of collapsing them', () => {
  assert.throws(() => buildCoverageInventory(['src/runtime.zig', 'src/runtime.zig']), /listed more than once/)
})

test('rejects duplicate source classes across reports instead of merging silently', () => {
  assert.throws(() => buildCoverageInventory(['src/runtime.zig'], [
    { scope: 'src', xml: cobertura('runtime.zig') },
    { scope: 'src', xml: cobertura('runtime.zig') },
  ]), /reported more than once/)
})

test('rejects unsafe or ambiguous report mappings', () => {
  for (const filename of ['/absolute.zig', '../runtime.zig', 'tests/engine.zig']) {
    assert.throws(() => buildCoverageInventory(['src/runtime.zig'], [
      { scope: 'src', xml: cobertura(filename) },
    ]))
  }
  assert.throws(() => buildCoverageInventory(['src/runtime.zig'], [
    { scope: 'unknown', xml: cobertura('runtime.zig') },
  ]), /Unknown source scope/)
})

test('lists every first-party Zig source and keeps unreported files separate', () => {
  const paths = [
    'bench/main.zig',
    'build.zig',
    'devtools/main.zig',
    'examples/embed.zig',
    'libs/a.zig',
    'src/a.zig',
    'tests/a.zig',
    'tools/a.zig',
  ]
  const result = buildCoverageInventory(paths, [
    { scope: 'src', xml: cobertura('a.zig') },
  ])

  assert.deepEqual(result.scopes.src.reportedFiles, ['src/a.zig'])
  assert.deepEqual(result.scopes.tools.unreportedFiles, ['tools/a.zig'])
  assert.deepEqual(result.scopes.tools.unreportedImplementationFiles, ['tools/a.zig'])
  assert.deepEqual(result.scopes.tools.unreportedTestFiles, [])
  assert.deepEqual(result.scopes.devtools.unreportedFiles, ['devtools/main.zig'])
  assert.deepEqual(result.scopes.bench.unreportedFiles, ['bench/main.zig'])
  assert.deepEqual(result.scopes.examples.unreportedFiles, ['examples/embed.zig'])
  assert.deepEqual(result.scopes.tests.unreportedFiles, ['tests/a.zig'])
  assert.equal(result.totalFiles, paths.length)
})
