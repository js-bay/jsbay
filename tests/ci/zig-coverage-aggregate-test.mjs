import assert from 'node:assert/strict'
import { test } from 'node:test'
import { mergeZigBackendReports, sourceLineCount } from '../../scripts/quality/zig-coverage-merge.mjs'

const file = (filename, lines) => `<class filename="${filename}"><lines>${lines.map(([number, hits]) => `<line number="${number}" hits="${hits}"/>`).join('')}</lines></class>`
const report = (...classes) => {
  const lines = classes.flatMap(source => [...source.matchAll(/<line\b([^>]*)\/>/g)])
  const covered = lines.filter(([, attrs]) => Number(attrs.match(/hits="(\d+)"/)?.[1]) > 0).length
  return `<coverage lines-covered="${covered}" lines-valid="${lines.length}"><packages><package><classes>${classes.join('')}</classes></package></packages></coverage>`
}
const backends = () => ({
  quickjs: report(file('runtime/host.zig', [[1, 0], [2, 1]]), file('backend/quickjs/engine.c', [[1, 1]])),
  quickjs_ng: report(file('runtime/host.zig', [[1, 1], [3, 0]]), file('backend/quickjs_ng/engine.c', [[1, 0]])),
  jsc: report(file('runtime/host.zig', [[2, 1], [4, 0]]), file('backend/jsc/module_loader.m', [[1, 1]])),
})

test('merges all three backends by source path and line and ORs hits', () => {
  const result = mergeZigBackendReports(backends())
  assert.deepEqual(result.backends, {
    quickjs: { linesCovered: 1, linesValid: 2 },
    quickjs_ng: { linesCovered: 1, linesValid: 2 },
    jsc: { linesCovered: 1, linesValid: 2 },
  })
  assert.deepEqual(result.merged, { linesCovered: 2, linesValid: 4 })
  assert.doesNotMatch(result.report, /\.c"/)
  assert.doesNotMatch(result.report, /\.m"/)
  assert.doesNotMatch(result.report, /branch-rate|branches-valid/)
})

test('requires every named engine input', () => {
  const input = backends()
  delete input.jsc
  assert.throws(() => mergeZigBackendReports(input), /exactly: quickjs, quickjs_ng, jsc/)
})

test('rejects duplicate classes and duplicate source lines within an engine input', () => {
  const input = backends()
  input.jsc = report(file('runtime/host.zig', [[2, 1]]) + file('runtime/host.zig', [[3, 0]]))
  assert.throws(() => mergeZigBackendReports(input), /duplicate source classes/)

  input.jsc = report(file('runtime/host.zig', [[2, 1], [2, 0]]))
  assert.throws(() => mergeZigBackendReports(input), /duplicate source lines/)
})

test('rejects paths and source lines that do not match the current checkout', () => {
  const input = backends()
  input.jsc = report(file('runtime/missing.zig', [[1, 0]]))
  assert.throws(() => mergeZigBackendReports(input), /ENOENT/)

  input.jsc = report(file('runtime/host.zig', [[100000, 0]]))
  assert.throws(() => mergeZigBackendReports(input), /exceeds the current file/)
})

test('rejects a report line one past a source file that ends with a newline', () => {
  const input = backends()
  input.jsc = report(file('runtime/host.zig', [[94, 0]]))
  assert.throws(() => mergeZigBackendReports(input), /exceeds the current file/)
})

test('counts source lines for empty files, final newlines, and CRLF', () => {
  assert.equal(sourceLineCount(''), 0)
  assert.equal(sourceLineCount('one'), 1)
  assert.equal(sourceLineCount('one\ntwo'), 2)
  assert.equal(sourceLineCount('one\ntwo\n'), 2)
  assert.equal(sourceLineCount('\r\n'), 1)
  assert.equal(sourceLineCount('one\r\ntwo'), 2)
  assert.equal(sourceLineCount('one\r\ntwo\r\n'), 2)
})
