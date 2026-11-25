import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { filterMultipleCoberturaInlineTests } from './zig-inline-test-coverage.mjs'

const repositoryRoot = resolve(fileURLToPath(new URL('../..', import.meta.url)))

function parseReport(xml, name) {
  const source = xml.replace(/<!--[\s\S]*?-->/g, ' ')
  const root = source.match(/<coverage\b([^>]*)>/)
  if (!root) throw new Error(`${name} report has no Cobertura root`)
  const rootAttributes = attributes(root[1])
  const declaredValid = integer(rootAttributes['lines-valid'], `${name} lines-valid`)
  const declaredCovered = integer(rootAttributes['lines-covered'], `${name} lines-covered`)
  const classes = [...source.matchAll(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g)]
  if (classes.length === 0) throw new Error(`${name} report has no source classes`)

  const lines = new Map()
  for (const [, rawAttributes, body] of classes) {
    const filename = attributes(rawAttributes).filename ?? ''
    const parts = filename.split('/')
    if (!/^[a-zA-Z0-9_./-]+\.(?:zig|c)$/.test(filename) || filename.startsWith('/') || parts.some(part => !part || part === '.' || part === '..' || part === 'tests')) {
      throw new Error(`${name} report contains a path outside the Zig source scope: ${filename}`)
    }
    if (lines.has(`${filename}:class`)) throw new Error(`${name} report contains duplicate source classes: ${filename}`)
    lines.set(`${filename}:class`, true)
    const section = body.match(/<lines\b[^>]*>([\s\S]*?)<\/lines\s*>/)
    if (!section) throw new Error(`${name} report has no line data for ${filename}`)
    for (const [, raw] of section[1].matchAll(/<line\b([^>]*)\/?\s*>/g)) {
      const lineAttributes = attributes(raw)
      const number = integer(lineAttributes.number, `${name} source line`)
      const hits = integer(lineAttributes.hits, `${name} source hits`)
      const key = `${filename}:${number}`
      if (lines.has(key)) throw new Error(`${name} report contains duplicate source lines: ${key}`)
      lines.set(key, { hit: hits > 0, zig: filename.endsWith('.zig') })
    }
  }
  const sourceLines = [...lines.entries()].filter(([key]) => !key.endsWith(':class'))
  const covered = sourceLines.filter(([, value]) => value.hit).length
  if (sourceLines.length !== declaredValid || covered !== declaredCovered) {
    throw new Error(`${name} report aggregate line counts disagree with its source lines`)
  }
  const zigLines = sourceLines.filter(([, value]) => value.zig).map(([key, value]) => [key, value.hit])
  return {
    lines: new Map(zigLines),
    summary: {
      linesCovered: zigLines.filter(([, hit]) => hit).length,
      linesValid: zigLines.length,
    },
  }
}

function attributes(source) {
  return Object.fromEntries([...source.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)]
    .map(([, key, doubleQuoted, singleQuoted]) => [key, doubleQuoted ?? singleQuoted]))
}

function integer(value, name) {
  const number = Number(value)
  if (!/^\d+$/.test(value ?? '') || !Number.isSafeInteger(number)) throw new Error(`${name} is invalid`)
  return number
}

function setAttribute(source, name, value) {
  const pattern = new RegExp(`(\\b${name}\\s*=\\s*)(?:"[^"]*"|'[^']*')`)
  if (!pattern.test(source)) return `${source} ${name}="${value}"`
  return source.replace(pattern, `$1"${value}"`)
}

function lineCounts(body) {
  const classes = [...body.matchAll(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g)]
  let covered = 0
  let valid = 0
  for (const [, rawAttributes, classBody] of classes) {
    const classAttributes = attributes(rawAttributes)
    covered += integer(classAttributes['lines-covered'], 'class lines-covered')
    valid += integer(classAttributes['lines-valid'], 'class lines-valid')
  }
  return { covered, valid }
}

function sourceLineCounts(body) {
  const section = body.match(/<lines\b[^>]*>([\s\S]*?)<\/lines\s*>/)
  if (!section) throw new Error('Cobertura class has no line data')
  const entries = [...section[1].matchAll(/<line\b([^>]*)\/?\s*>/g)]
  let covered = 0
  const seen = new Set()
  for (const [, raw] of entries) {
    const attrs = attributes(raw)
    const number = integer(attrs.number, 'source line number')
    const hits = integer(attrs.hits, 'source line hits')
    if (seen.has(number)) throw new Error('Cobertura class has duplicate source lines')
    seen.add(number)
    if (hits > 0) covered++
  }
  return { covered, valid: entries.length }
}

function rewriteCounts(tag, rawAttributes, body, counts) {
  const rate = counts.valid === 0 ? '1.000' : (counts.covered / counts.valid).toFixed(3)
  let updated = setAttribute(rawAttributes, 'lines-covered', counts.covered)
  updated = setAttribute(updated, 'lines-valid', counts.valid)
  updated = setAttribute(updated, 'line-rate', rate)
  return `<${tag}${updated}>${body}</${tag}>`
}

function filterToZig(xml) {
  let output = xml.replace(/<!--[\s\S]*?-->/g, ' ')
  if (/<method\b/.test(output)) throw new Error('Cobertura method-level data cannot be merged by source line')
  output = output.replace(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g, (block, rawAttributes, body) => {
    const filename = attributes(rawAttributes).filename ?? ''
    return filename.endsWith('.zig') ? rewriteCounts('class', rawAttributes, body, sourceLineCounts(body)) : ''
  })
  output = output.replace(/<package\b([^>]*)>([\s\S]*?)<\/package\s*>/g, (_, attrs, body) => rewriteCounts('package', attrs, body, lineCounts(body)))
  const root = output.match(/<coverage\b([^>]*)>([\s\S]*?)<\/coverage\s*>/)
  if (!root) throw new Error('Merged report has no Cobertura root')
  return output.replace(root[0], rewriteCounts('coverage', root[1], root[2], lineCounts(root[2])))
}

export function validateMergedCoverage(quickjsXml, quickjsNgXml, mergedXml) {
  parseReport(quickjsXml, 'QuickJS')
  parseReport(quickjsNgXml, 'QuickJS-NG')
  parseReport(mergedXml, 'Merged')
  const zigReports = [quickjsXml, quickjsNgXml, mergedXml].map(filterToZig)
  const [quickjsFiltered, quickjsNgFiltered, mergedFiltered] = filterMultipleCoberturaInlineTests(
    zigReports,
    resolve(repositoryRoot, 'src'),
  )
  const quickjs = parseReport(quickjsFiltered, 'QuickJS')
  const quickjsNg = parseReport(quickjsNgFiltered, 'QuickJS-NG')
  const zigOnlyMergedXml = mergedFiltered
  const merged = parseReport(zigOnlyMergedXml, 'Merged')
  const expected = new Map([...quickjs.lines, ...quickjsNg.lines])
  for (const [key, hit] of quickjsNg.lines) {
    if (quickjs.lines.has(key)) expected.set(key, quickjs.lines.get(key) || hit)
  }
  if (expected.size !== merged.lines.size) throw new Error('Merged report does not match the backend source-line union')
  for (const [key, hit] of expected) {
    if (merged.lines.get(key) !== hit) throw new Error(`Merged report does not match the backend source-line union at ${key}`)
  }
  return {
    backends: { quickjs: quickjs.summary, quickjs_ng: quickjsNg.summary },
    merged: merged.summary,
    report: zigOnlyMergedXml,
  }
}

if (process.argv[1]?.endsWith('/zig-coverage-merge.mjs')) {
  if (process.argv.length !== 6) throw new Error('Usage: zig-coverage-merge.mjs <quickjs-report> <quickjs-ng-report> <merged-report> <zig-only-output>')
  try {
    const [quickjs, quickjsNg, merged] = process.argv.slice(2, 5).map(path => readFileSync(path, 'utf8'))
    const result = validateMergedCoverage(quickjs, quickjsNg, merged)
    writeFileSync(process.argv[5], result.report)
    delete result.report
    process.stdout.write(JSON.stringify(result) + '\n')
  } catch (error) {
    console.error(error.message)
    process.exitCode = 2
  }
}
