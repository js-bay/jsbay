import { accessSync, constants, readFileSync } from 'node:fs'
import { resolve, sep } from 'node:path'

const packageNames = [
  'bytecode_cache',
  'cmph',
  'commonjs',
  'hyper_box',
  'inspector',
  'inspector_transport',
  'js_event_loop',
  'simd_utf',
  'zev',
]

function packageTestBinaries(log, cacheDirectory) {
  const cache = resolve(cacheDirectory)
  const expectedRoots = new Set(packageNames)
  const roots = []
  const binaries = []
  const executablePattern = /^info\(verbose\): (.+)\/o\/([a-f0-9]{32})\/test --cache-dir=(\S+) --seed=/

  for (const line of log.split(/\r?\n/)) {
    if (line.includes('zig test ') && line.includes('-Mroot=libs/')) {
      for (const match of line.matchAll(/-Mroot=libs\/([^/]+)\/src\/tests\.zig(?=\s|$)/g)) {
        if (!expectedRoots.has(match[1])) throw new Error('unexpected package test root: ' + match[1])
        roots.push(match[1])
      }
    }

    const executable = line.match(executablePattern)
    if (!executable) continue
    const binary = resolve(executable[1], 'o', executable[2], 'test')
    if (resolve(executable[1]) !== cache || executable[3] !== cache || !binary.startsWith(cache + sep + 'o' + sep)) {
      throw new Error('test executable is outside the requested cache')
    }
    binaries.push(binary)
  }

  if (roots.length !== packageNames.length || new Set(roots).size !== packageNames.length || roots.some(name => !expectedRoots.has(name))) {
    throw new Error('expected all 9 package test roots exactly once; found ' + roots.join(', '))
  }

  if (binaries.length !== packageNames.length || new Set(binaries).size !== packageNames.length) {
    throw new Error('expected 9 distinct package test executables; found ' + binaries.length)
  }

  for (const binary of binaries) {
    try {
      accessSync(binary, constants.X_OK)
    } catch {
      throw new Error('package test executable is missing or not executable: ' + binary)
    }
  }

  return binaries
}

export { packageTestBinaries }

if (process.argv[1]?.endsWith('/zig-package-coverage-targets.mjs')) {
  if (process.argv.length !== 4) throw new Error('Usage: zig-package-coverage-targets.mjs <build-log> <cache-directory>')
  const [, , logPath, cacheDirectory] = process.argv
  process.stdout.write(packageTestBinaries(readFileSync(logPath, 'utf8'), cacheDirectory).join('\n') + '\n')
}
