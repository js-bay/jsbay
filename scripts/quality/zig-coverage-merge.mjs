import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
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
    if (!/^[a-zA-Z0-9_./-]+\.(?:zig|c|m)$/.test(filename) || filename.startsWith('/') || parts.some(part => !part || part === '.' || part === '..' || part === 'tests')) {
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

function validateSourceLineBounds(xml) {
  const classes = [...xml.matchAll(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g)]
  for (const [, rawAttributes, body] of classes) {
    const filename = attributes(rawAttributes).filename
    const path = realpathSync(resolve(repositoryRoot, 'src', filename))
    const source = readFileSync(path, 'utf8')
    const lineCount = sourceLineCount(source)
    for (const [, raw] of body.matchAll(/<line\b([^>]*)\/?\s*>/g)) {
      const number = integer(attributes(raw).number, 'source line')
      if (number > lineCount) throw new Error(`Report source line exceeds the current file: ${filename}:${number}`)
    }
  }
}

export function sourceLineCount(source) {
  if (source.length === 0) return 0
  const newlineCount = source.match(/\n/g)?.length ?? 0
  return newlineCount + (source.endsWith('\n') ? 0 : 1)
}

function escapeXml(value) {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

function mergedCobertura(lines) {
  const files = new Map()
  for (const [key, hit] of lines) {
    const separator = key.lastIndexOf(':')
    const filename = key.slice(0, separator)
    const number = Number(key.slice(separator + 1))
    if (!files.has(filename)) files.set(filename, new Map())
    files.get(filename).set(number, hit)
  }
  let covered = 0
  let valid = 0
  const classes = [...files].sort(([left], [right]) => left.localeCompare(right)).map(([filename, sourceLines]) => {
    const lineCount = sourceLines.size
    const lineCovered = [...sourceLines.values()].filter(Boolean).length
    const rate = lineCount === 0 ? '1.000' : (lineCovered / lineCount).toFixed(3)
    covered += lineCovered
    valid += lineCount
    const name = filename.slice(filename.lastIndexOf('/') + 1, -4)
    const lineXml = [...sourceLines].sort(([left], [right]) => left - right)
      .map(([number, hit]) => `<line number="${number}" hits="${hit ? 1 : 0}"/>`).join('')
    return `<class name="${escapeXml(name)}" filename="${escapeXml(filename)}" line-rate="${rate}" lines-covered="${lineCovered}" lines-valid="${lineCount}" complexity="0"><lines>${lineXml}</lines></class>`
  }).join('')
  const rate = valid === 0 ? '1.000' : (covered / valid).toFixed(3)
  return `<coverage line-rate="${rate}" lines-covered="${covered}" lines-valid="${valid}" complexity="0" version="1.9"><sources><source>src</source></sources><packages><package name="compiled-zig" line-rate="${rate}" lines-covered="${covered}" lines-valid="${valid}" complexity="0"><classes>${classes}</classes></package></packages></coverage>`
}

export function mergeZigBackendReports(backendReports) {
  const requiredBackends = ['quickjs', 'quickjs_ng', 'jsc']
  const actualBackends = Object.keys(backendReports).sort()
  if (actualBackends.length !== requiredBackends.length || requiredBackends.some(name => !Object.hasOwn(backendReports, name))) {
    throw new Error(`Expected reports for exactly: ${requiredBackends.join(', ')}`)
  }

  const names = requiredBackends
  const rawReports = names.map(name => {
    if (typeof backendReports[name] !== 'string' || backendReports[name].length === 0) {
      throw new Error(`${name} report is missing or empty`)
    }
    parseReport(backendReports[name], name)
    return filterToZig(backendReports[name])
  })
  const filteredReports = filterMultipleCoberturaInlineTests(rawReports, resolve(repositoryRoot, 'src'))
  for (const report of filteredReports) validateSourceLineBounds(report)
  const perBackend = Object.fromEntries(names.map((name, index) => [name, parseReport(filteredReports[index], name)]))
  const union = new Map()
  for (const name of names) {
    for (const [key, hit] of perBackend[name].lines) {
      union.set(key, (union.get(key) ?? false) || hit)
    }
  }
  const report = mergedCobertura(union)
  const merged = parseReport(report, 'Merged')
  if (merged.lines.size !== union.size) throw new Error('Merged report does not match the backend source-line union')
  for (const [key, hit] of union) {
    if (merged.lines.get(key) !== hit) throw new Error(`Merged report does not match the backend hit union at ${key}`)
  }
  return {
    backends: Object.fromEntries(names.map(name => [name, perBackend[name].summary])),
    merged: merged.summary,
    report,
  }
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
