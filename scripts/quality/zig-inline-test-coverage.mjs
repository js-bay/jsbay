import { randomUUID } from 'node:crypto'
import { closeSync, constants as fsConstants, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const libsRoot = realpathSync(resolve(root, 'libs'))

function attributes(source) {
  return Object.fromEntries([...source.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)]
    .map(([, name, doubleQuoted, singleQuoted]) => [name, doubleQuoted ?? singleQuoted]))
}

function setAttribute(source, name, value) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const pattern = new RegExp(`(\\b${escaped}\\s*=\\s*)(?:"[^"]*"|'[^']*')`)
  if (!pattern.test(source)) return source + ` ${name}="${value}"`
  return source.replace(pattern, `$1"${value}"`)
}

function countLineElements(lines) {
  let covered = 0
  const seen = new Set()
  for (const [, raw] of lines) {
    const line = Number(attributes(raw).number)
    const hits = Number(attributes(raw).hits)
    if (!Number.isSafeInteger(line) || line <= 0 || seen.has(line) || !Number.isSafeInteger(hits) || hits < 0) {
      throw new Error('Cobertura class has invalid or duplicate line data')
    }
    seen.add(line)
    if (hits > 0) covered++
  }
  return { covered, valid: lines.length }
}

function classLineCounts(body) {
  const sections = [...body.matchAll(/<lines\b[^>]*>([\s\S]*?)<\/lines\s*>/g)]
  if (sections.length === 0) throw new Error('Cobertura class has no lines section')
  return countLineElements([...sections.at(-1)[1].matchAll(/<line\b([^>]*)\/?\s*>/g)])
}

function aggregateClassCounts(body) {
  const classes = [...body.matchAll(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g)]
  let covered = 0
  let valid = 0
  for (const [, rawAttributes] of classes) {
    const attrs = attributes(rawAttributes)
    const classCovered = Number(attrs['lines-covered'])
    const classValid = Number(attrs['lines-valid'])
    if (!Number.isSafeInteger(classCovered) || !Number.isSafeInteger(classValid) || classCovered < 0 || classValid < classCovered) {
      throw new Error('Cobertura class has invalid aggregate line counts')
    }
    covered += classCovered
    valid += classValid
  }
  return { covered, valid }
}

function setCounts(tag, rawAttributes, body, counts) {
  const { covered, valid } = counts
  const rate = valid === 0 ? '1.000' : (covered / valid).toFixed(3)
  let updated = setAttribute(rawAttributes, 'lines-covered', covered)
  updated = setAttribute(updated, 'lines-valid', valid)
  updated = setAttribute(updated, 'line-rate', rate)
  return `<${tag}${updated}>${body}</${tag}>`
}

function replaceTagBlocks(source, tag) {
  const pattern = new RegExp(`<${tag}\\b([^>]*)>([\\s\\S]*?)<\\/${tag}\\s*>`, 'g')
  return source.replace(pattern, (_, attrs, body) => setCounts(tag, attrs, body, aggregateClassCounts(body)))
}

function removeKcovBranchPlaceholders(xml) {
  if (/<condition\b|\bcondition-coverage\s*=|\bbranch\s*=\s*(?:"(?:true|1)"|'(?:true|1)')/i.test(xml)) {
    throw new Error('Cobertura contains branch condition data that cannot be filtered')
  }
  const branchAttributes = new Set(['branch-rate', 'branches-covered', 'branches-rate', 'branches-valid'])
  return xml.replace(/<(coverage|package|class)\b([^>]*)>/g, (tag, name, rawAttributes) => {
    const attrs = attributes(rawAttributes)
    for (const [key, value] of Object.entries(attrs)) {
      if (!branchAttributes.has(key)) continue
      if (key === 'branches-valid' || value !== '1.0') {
        throw new Error(`Cobertura contains branch data that cannot be filtered: ${name} ${key}=${value}`)
      }
    }
    const cleaned = rawAttributes.replace(/\s+(?:branch-rate|branches-covered|branches-rate|branches-valid)\s*=\s*(?:"[^"]*"|'[^']*')/g, '')
    return `<${name}${cleaned}>`
  })
}

export function filterCoberturaInlineTests(xml, astLinesByFile) {
  const withoutComments = xml.replace(/<!--[\s\S]*?-->/g, ' ')
  const cleaned = removeKcovBranchPlaceholders(withoutComments)
  if (/<method\b/.test(cleaned)) throw new Error('Cobertura method-level data cannot be filtered by source line')
  const classes = [...cleaned.matchAll(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g)]
  if (classes.length === 0) throw new Error('Cobertura report has no classes')

  const filteredClasses = []
  for (const [, rawAttributes, body] of classes) {
    const filename = attributes(rawAttributes).filename ?? ''
    const linesToExclude = astLinesByFile.get(filename)
    if (!linesToExclude) throw new Error(`AST result is missing source file ${filename}`)
    const lines = [...body.matchAll(/<lines\b[^>]*>[\s\S]*?<\/lines\s*>/g)].at(-1)
    if (!lines) throw new Error(`Cobertura class has no lines section: ${filename}`)
    const keptLines = lines[0].replace(/<line\b([^>]*)\/?\s*>/g, (lineTag, raw) => {
      const number = Number(attributes(raw).number)
      return linesToExclude.has(number) ? '' : lineTag
    })
    const updatedBody = body.replace(lines[0], keptLines)
    filteredClasses.push(setCounts('class', rawAttributes, updatedBody, classLineCounts(updatedBody)))
  }

  let classIndex = 0
  let output = cleaned.replace(/<class\b[^>]*>[\s\S]*?<\/class\s*>/g, () => filteredClasses[classIndex++])
  output = replaceTagBlocks(output, 'package')
  const coverage = output.match(/<coverage\b([^>]*)>([\s\S]*?)<\/coverage\s*>/)
  if (!coverage) throw new Error('Cobertura report has no coverage root')
  output = output.replace(coverage[0], setCounts('coverage', coverage[1], coverage[2], aggregateClassCounts(coverage[2])))
  return output
}

function probeSource(sourceFiles) {
  const fileInitializers = sourceFiles.map(({ filename, expression, embedded }) => {
    if (!/^[a-z0-9_/-]+\.zig$/.test(filename) || filename.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new Error(`Unsafe Cobertura source path: ${filename}`)
    }
    if (embedded) {
      const sourcePath = realpathSync(resolve(libsRoot, filename))
      if (!sourcePath.startsWith(libsRoot + '/')) throw new Error(`Cobertura source escapes libs/: ${filename}`)
    }
    return `    .{ .filename = ${JSON.stringify(filename)}, .source = ${expression} },`
  }).join('\n')
  return `const std = @import("std");
const Source = struct { filename: []const u8, source: [:0]const u8 };
const sources = [_]Source{\n${fileInitializers}\n};

fn lineNumber(source: []const u8, offset: usize) usize {
    return 1 + std.mem.count(u8, source[0..offset], "\\n");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (sources, 0..) |source, source_index| {
        var tree = try std.zig.Ast.parse(allocator, source.source, .{});
        if (tree.errors.len != 0) {
            const error_token = tree.errors[0].token;
            const error_line = lineNumber(source.source, tree.tokenStart(error_token));
            std.debug.print("AST parse failed for {s}:{d} ({s}) with {d} errors\\n", .{ source.filename, error_line, @tagName(tree.errors[0].tag), tree.errors.len });
            return error.AstParseFailed;
        }
        var ranges = std.ArrayList([2]usize).empty;
        for (tree.nodes.items(.tag), 0..) |tag, index| {
            if (tag != .test_decl) continue;
            const node: std.zig.Ast.Node.Index = @enumFromInt(index);
            const first = tree.firstToken(node);
            const last = tree.lastToken(node);
            const start: usize = @intCast(tree.tokenStart(first));
            const end: usize = @intCast(tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len)));
            try ranges.append(allocator, .{ start, end });
            const start_line = lineNumber(source.source, start);
            const end_line = lineNumber(source.source, end);
            for (start_line..end_line + 1) |line| std.debug.print("ASTLINE {d} {d}\\n", .{ source_index, line });
        }
        const token_tags = tree.tokens.items(.tag);
        for (tree.tokens.items(.start), 0..) |token_start, token_index| {
            const start: usize = token_start;
            const token: std.zig.Ast.TokenIndex = @intCast(token_index);
            const end = start + tree.tokenSlice(token).len;
            const first_token_line = lineNumber(source.source, start);
            const last_token_line = lineNumber(source.source, end);
            var on_test_line = false;
            var inside_test = false;
            for (ranges.items) |range| {
                const first_line = lineNumber(source.source, range[0]);
                const last_line = lineNumber(source.source, range[1]);
                if (last_token_line >= first_line and first_token_line <= last_line) on_test_line = true;
                if (start >= range[0] and end <= range[1]) inside_test = true;
            }
            if (on_test_line and !inside_test and token_tags[token_index] != .eof) {
                for (first_token_line..last_token_line + 1) |line| {
                    std.debug.print("ASTMIX {d} {d}\\n", .{ source_index, line });
                }
            }
        }
    }
}
`
}

function runAstProbe(sourceFiles, zigBinary) {
  const sourcePath = resolve(root, `.zig-inline-test-${randomUUID()}.zig`)
  const cachePath = mkdtempSync(resolve(tmpdir(), 'jsbay-zig-ast-'))
  let sourceCreated = false
  try {
    const descriptor = openSync(sourcePath, fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_WRONLY, 0o600)
    sourceCreated = true
    try {
      writeFileSync(descriptor, probeSource(sourceFiles))
    } finally {
      closeSync(descriptor)
    }
    const result = spawnSync(zigBinary, ['run', sourcePath, '--cache-dir', cachePath], { cwd: root, encoding: 'utf8' })
    if (result.status !== 0) throw new Error(`Zig AST probe failed:\n${result.stderr || result.stdout}`)
    const output = result.stderr + result.stdout
    const byIndex = new Map(sourceFiles.map(({ filename }, index) => [index, { filename, lines: new Set(), mixed: new Set() }]))
    for (const line of output.split(/\r?\n/)) {
      const match = line.match(/^AST(LINE|MIX) (\d+) (\d+)$/)
      if (!match) continue
      const file = byIndex.get(Number(match[2]))
      if (match[1] === 'LINE') file.lines.add(Number(match[3]))
      else file.mixed.add(Number(match[3]))
    }
    return byIndex
  } finally {
    if (sourceCreated) rmSync(sourcePath, { force: true })
    rmSync(cachePath, { recursive: true, force: true })
  }
}

export function analyzeZigSources(sourceEntries, zigBinary = process.env.ZIG ?? 'zig') {
  const encoded = sourceEntries.map(({ filename, source }) => ({
    filename,
    embedded: false,
    expression: `&[_:0]u8{${[...Buffer.from(source)].join(',')}}`,
  }))
  const records = runAstProbe(encoded, zigBinary)
  return new Map([...records.values()].map(({ filename, lines, mixed }) => [filename, { lines, mixed }]))
}

function collectAstLines(xml, zigBinary) {
  const classes = [...xml.matchAll(/<class\b([^>]*)>/g)]
  const sourceFiles = classes.map(([, attrs]) => {
    const filename = attributes(attrs).filename ?? ''
    if (!/^[a-z0-9_/-]+\.zig$/.test(filename) || filename.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new Error(`Unsafe Cobertura source path: ${filename}`)
    }
    return { filename, embedded: true, expression: `@embedFile(${JSON.stringify(`libs/${filename}`)})` }
  })
  const filenames = sourceFiles.map(({ filename }) => filename)
  if (new Set(filenames).size !== filenames.length) throw new Error('Cobertura report contains duplicate source classes')
  const records = runAstProbe(sourceFiles, zigBinary)
  const map = new Map()
  for (const { filename, lines, mixed } of records.values()) {
    if (mixed.size > 0) throw new Error(`Inline test shares a source line with other code: ${filename}:${Math.min(...mixed)}`)
    map.set(filename, lines)
  }
  return map
}

function runCli() {
  const xml = readFileSync(0, 'utf8')
  const zigBinary = process.env.ZIG ?? 'zig'
  const astLines = collectAstLines(xml, zigBinary)
  process.stdout.write(filterCoberturaInlineTests(xml, astLines))
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    runCli()
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
