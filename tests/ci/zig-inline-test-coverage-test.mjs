import assert from 'node:assert/strict'
import { test } from 'node:test'
import { analyzeZigSources, filterCoberturaInlineTests } from '../../scripts/quality/zig-inline-test-coverage.mjs'

const xml = `<coverage line-rate="1" lines-covered="5" lines-valid="5"><packages><package name="bytecode_cache" line-rate="1" lines-covered="5" lines-valid="5"><classes><class filename="bytecode_cache/src/root.zig" line-rate="1" lines-covered="5" lines-valid="5"><lines><line number="1" hits="1"/><line number="2" hits="1"/><line number="3" hits="0"/><line number="4" hits="1"/><line number="5" hits="0"/></lines></class></classes></package></packages></coverage>`

test('removes AST test lines and recalculates class, package, and root line totals', () => {
  const result = filterCoberturaInlineTests(xml, new Map([
    ['bytecode_cache/src/root.zig', new Set([3, 4])],
  ]))
  assert.match(result, /<coverage line-rate="0\.667" lines-covered="2" lines-valid="3">/)
  assert.match(result, /<package name="bytecode_cache" line-rate="0\.667" lines-covered="2" lines-valid="3">/)
  assert.match(result, /<class filename="bytecode_cache\/src\/root.zig" line-rate="0\.667" lines-covered="2" lines-valid="3">/)
  assert.doesNotMatch(result, /<line number="3"|<line number="4"/)
})

test('fails closed when Cobertura contains method-level totals that cannot be reconciled by line filtering', () => {
  const withMethod = xml.replace('<lines><line number="1"', '<methods><method name="f"/></methods><lines><line number="1"')
  assert.throws(() => filterCoberturaInlineTests(withMethod, new Map([
    ['bytecode_cache/src/root.zig', new Set([3])],
  ])), /method-level data cannot be filtered/)
})

test('removes kcov placeholder branch attributes without presenting them as branch coverage', () => {
  const placeholders = xml
    .replace('<coverage ', '<coverage branch-rate="1.0" branches-covered="1.0" branches-rate="1.0" ')
    .replace('<package ', '<package branch-rate="1.0" ')
    .replace('<class ', '<class branch-rate="1.0" ')
  const result = filterCoberturaInlineTests(placeholders, new Map([
    ['bytecode_cache/src/root.zig', new Set([3])],
  ]))
  assert.doesNotMatch(result, /branch-rate|branches-covered|branches-rate|branches-valid/)
})

test('fails closed when Cobertura reports real branch data', () => {
  const realBranches = xml.replace('<coverage ', '<coverage branch-rate="0.5" branches-valid="4" branches-covered="2" ')
  assert.throws(() => filterCoberturaInlineTests(realBranches, new Map([
    ['bytecode_cache/src/root.zig', new Set([3])],
  ])), /branch data that cannot be filtered/)
  const conditions = xml.replace('<line number="3" hits="0"/>', '<line number="3" hits="0" branch="true" condition-coverage="50%"><conditions><condition number="0" type="jump" coverage="50%"/></conditions></line>')
  assert.throws(() => filterCoberturaInlineTests(conditions, new Map([
    ['bytecode_cache/src/root.zig', new Set([3])],
  ])), /branch condition data that cannot be filtered/)
})

test('fails closed when an AST result omits a Cobertura source class', () => {
  assert.throws(() => filterCoberturaInlineTests(xml, new Map()), /AST result is missing source file bytecode_cache\/src\/root.zig/)
})

test('Zig AST ignores test words in comments and strings, and locates multiline and nested declarations', () => {
  const analyzed = analyzeZigSources([{
    filename: 'fixture.zig',
    source: `// test "comment" { }\nconst text = "test \\\"string\\\" { }";\nconst Nested = struct {\n    test "nested" {\n        _ = text;\n    }\n};\ntest\n"outer" {\n    const nested_text = "test";\n}\n`,
  }])
  assert.deepEqual([...analyzed.get('fixture.zig').lines].sort((a, b) => a - b), [4, 5, 6, 8, 9, 10, 11])
  assert.deepEqual([...analyzed.get('fixture.zig').mixed], [])
})

test('Zig AST reports same-line production tokens as an unsafe mixed line', () => {
  const analyzed = analyzeZigSources([{
    filename: 'mixed.zig',
    source: `const production = 1; test "inline" {\n    _ = production;\n}\n`,
  }])
  assert.deepEqual([...analyzed.get('mixed.zig').mixed], [1])
  assert.deepEqual([...analyzed.get('mixed.zig').lines], [1, 2, 3])
})
