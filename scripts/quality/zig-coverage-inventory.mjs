import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'

const sourceScopes = ['bench', 'devtools', 'examples', 'libs', 'src', 'tests', 'tools', 'root']

function attributes(source) {
  return Object.fromEntries([...source.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)]
    .map(([, name, doubleQuoted, singleQuoted]) => [name, doubleQuoted ?? singleQuoted]))
}

function safeSourcePath(filename, scope) {
  if (typeof filename !== 'string' || filename.length === 0 || filename.startsWith('/') || filename.includes('\\')) return false
  const parts = filename.split('/')
  if (parts.some(part => !part || part === '.' || part === '..')) return false
  if (scope === 'root') return parts.length === 1
  return true
}

function isTestFile(path) {
  const parts = path.split('/')
  const basename = parts.at(-1)
  return parts.includes('tests') || /^(?:test.*|.*_tests?|tests)\.zig$/.test(basename)
}

function parseReport(xml, scope) {
  if (!sourceScopes.includes(scope)) throw new Error(`Unknown source scope: ${scope}`)
  const source = xml.replace(/<!--[\s\S]*?-->/g, ' ')
  if (!/<coverage\b/.test(source)) throw new Error(`${scope} report has no Cobertura root`)
  const classes = [...source.matchAll(/<class\b([^>]*)>/g)]
  if (classes.length === 0) throw new Error(`${scope} report has no source classes`)
  const paths = new Set()
  const ignoredNonZig = []
  for (const [, raw] of classes) {
    const filename = attributes(raw).filename ?? ''
    if (!safeSourcePath(filename, scope)) throw new Error(`${scope} report contains an unsafe source path: ${filename}`)
    if (!filename.endsWith('.zig')) {
      ignoredNonZig.push(filename)
      continue
    }
    const path = scope === 'root' ? filename : `${scope}/${filename}`
    if (paths.has(path)) throw new Error(`Source is reported more than once: ${path}`)
    paths.add(path)
  }
  return { paths, ignoredNonZig: [...new Set(ignoredNonZig)].sort() }
}

export function buildCoverageInventory(trackedPaths, reports = []) {
  const tracked = trackedPaths.filter(path => path.endsWith('.zig')).sort()
  const knownFiles = new Set()
  const scopes = Object.fromEntries(sourceScopes.map(scope => [scope, []]))

  for (const path of tracked) {
    if (path.startsWith('/') || path.includes('\\') || path.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new Error(`Tracked Zig path is unsafe: ${path}`)
    }
    const parts = path.split('/')
    const scope = parts.length === 1 ? 'root' : parts[0]
    if (!sourceScopes.includes(scope)) throw new Error(`Unclassified first-party Zig source: ${path}`)
    if (scope === 'root' && path !== 'build.zig') throw new Error(`Unclassified root-level Zig source: ${path}`)
    if (knownFiles.has(path)) throw new Error(`Tracked Zig source is listed more than once: ${path}`)
    knownFiles.add(path)
    scopes[scope].push({ path, category: isTestFile(path) ? 'test' : 'implementation', status: 'unreported' })
  }

  const reported = new Set()
  const ignoredNonZigReportPaths = Object.fromEntries(sourceScopes.map(scope => [scope, new Set()]))
  for (const report of reports) {
    if (!report || typeof report.xml !== 'string') {
      throw new Error('Each report must provide an explicit source scope and Cobertura XML')
    }
    const parsed = parseReport(report.xml, report.scope)
    for (const path of parsed.ignoredNonZig) ignoredNonZigReportPaths[report.scope].add(path)
    for (const path of parsed.paths) {
      if (!knownFiles.has(path)) throw new Error(`Coverage report path is not a tracked Zig source: ${path}`)
      if (reported.has(path)) throw new Error(`Tracked Zig source is reported more than once: ${path}`)
      reported.add(path)
    }
  }

  const resultScopes = {}
  for (const scope of sourceScopes) {
    const files = scopes[scope].map(file => ({ ...file, status: reported.has(file.path) ? 'reported' : 'unreported' }))
    const unreportedFiles = files.filter(file => file.status === 'unreported')
    resultScopes[scope] = {
      reportedFiles: files.filter(file => file.status === 'reported').map(file => file.path),
      unreportedFiles: unreportedFiles.map(file => file.path),
      unreportedImplementationFiles: unreportedFiles.filter(file => file.category === 'implementation').map(file => file.path),
      unreportedTestFiles: unreportedFiles.filter(file => file.category === 'test').map(file => file.path),
      ignoredNonZigReportPaths: [...ignoredNonZigReportPaths[scope]].sort(),
      files,
    }
  }
  const testFiles = tracked.filter(isTestFile)
  return {
    totalFiles: tracked.length,
    testFiles,
    scopes: resultScopes,
  }
}

function readTrackedPaths(repository) {
  const result = spawnSync('git', ['-C', repository, 'ls-files', '-z', '--', '*.zig'], { encoding: 'buffer' })
  if (result.status !== 0) throw new Error(`Could not list tracked Zig files: ${result.stderr.toString()}`)
  return result.stdout.toString().split('\0').filter(Boolean)
}

function runCli() {
  const args = process.argv.slice(2)
  let repository = process.cwd()
  const reports = []
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--repo' && args[index + 1]) {
      repository = args[++index]
      continue
    }
    if (args[index] === '--report' && args[index + 1]) {
      const [scope, reportPath, ...extra] = args[++index].split('=')
      if (!scope || !reportPath || extra.length !== 0) throw new Error('Expected --report <scope>=<cobertura.xml>')
      reports.push({ scope, xml: readFileSync(reportPath, 'utf8') })
      continue
    }
    throw new Error('Usage: zig-coverage-inventory.mjs [--repo <path>] [--report <scope>=<cobertura.xml> ...]')
  }
  const result = buildCoverageInventory(readTrackedPaths(repository), reports)
  process.stdout.write(JSON.stringify(result, null, 2) + '\n')
}

if (process.argv[1]?.endsWith('/zig-coverage-inventory.mjs')) {
  try {
    runCli()
  } catch (error) {
    console.error(error.message)
    process.exitCode = 2
  }
}
