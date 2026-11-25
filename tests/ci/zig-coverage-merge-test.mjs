import assert from 'node:assert/strict'
import { test } from 'node:test'
import { validateMergedCoverage } from '../../scripts/quality/zig-coverage-merge.mjs'

const report = (classes, covered, valid) => `<coverage lines-covered="${covered}" lines-valid="${valid}"><packages><package><classes>${classes}</classes></package></packages></coverage>`
const file = (filename, lines) => `<class filename="${filename}"><lines>${lines.map(([number, hits]) => `<line number="${number}" hits="${hits}"/>`).join('')}</lines></class>`

test('validates merged source-line union and deduplicates shared backend lines', () => {
  const quickjs = report(file('backend/quickjs_ng/console.zig', [[1, 1], [2, 0]]), 1, 2)
  const quickjsNg = report(file('backend/quickjs_ng/console.zig', [[1, 0], [2, 1]]) + file('backend/quickjs_ng/module.zig', [[3, 1]]), 2, 3)
  const merged = report(file('backend/quickjs_ng/console.zig', [[1, 1], [2, 1]]) + file('backend/quickjs_ng/module.zig', [[3, 1]]), 3, 3)

  const result = validateMergedCoverage(quickjs, quickjsNg, merged)
  assert.deepEqual({ backends: result.backends, merged: result.merged }, {
    backends: {
      quickjs: { linesCovered: 1, linesValid: 2 },
      quickjs_ng: { linesCovered: 2, linesValid: 3 },
    },
    merged: { linesCovered: 3, linesValid: 3 },
  })
  assert.doesNotMatch(result.report, /engine\.c/)
})

test('omits known C engine files from the Zig-only merged denominator', () => {
  const quickjs = report(file('backend/quickjs_ng/console.zig', [[1, 1]]) + file('engine.c', [[4, 1]]), 2, 2)
  const quickjsNg = report(file('backend/quickjs_ng/console.zig', [[1, 0]]) + file('engine.c', [[4, 1], [5, 0]]), 1, 3)
  const merged = report(file('backend/quickjs_ng/console.zig', [[1, 1]]) + file('engine.c', [[4, 1], [5, 0]]), 2, 3)

  const result = validateMergedCoverage(quickjs, quickjsNg, merged)
  assert.deepEqual({ backends: result.backends, merged: result.merged }, {
    backends: {
      quickjs: { linesCovered: 1, linesValid: 1 },
      quickjs_ng: { linesCovered: 0, linesValid: 1 },
    },
    merged: { linesCovered: 1, linesValid: 1 },
  })
  assert.doesNotMatch(result.report, /engine\.c/)
})

test('rejects a merged report that loses a backend-only source line', () => {
  const quickjs = report(file('backend/quickjs_ng/console.zig', [[1, 1]]), 1, 1)
  const quickjsNg = report(file('backend/quickjs_ng/console.zig', [[1, 1], [2, 0]]), 1, 2)
  const incomplete = report(file('backend/quickjs_ng/console.zig', [[1, 1]]), 1, 1)

  assert.throws(() => validateMergedCoverage(quickjs, quickjsNg, incomplete), /source-line union/)
})

test('rejects coverage that includes tests or paths outside src', () => {
  const valid = report(file('backend/quickjs_ng/console.zig', [[1, 1]]), 1, 1)
  const tests = report(file('tests/example.zig', [[1, 1]]), 1, 1)
  assert.throws(() => validateMergedCoverage(tests, valid, valid), /source scope/)
  assert.throws(() => validateMergedCoverage(valid, report(file('../outside.zig', [[1, 1]]), 1, 1), valid), /source scope/)
})

test('rejects report aggregates that disagree with source lines', () => {
  const bad = report(file('backend/quickjs_ng/console.zig', [[1, 1]]), 0, 1)
  assert.throws(() => validateMergedCoverage(bad, bad, bad), /aggregate line counts/)
})
