import { readFileSync, writeFileSync } from 'node:fs'
import { mergeZigBackendReports } from './zig-coverage-merge.mjs'

function runCli() {
  const reports = {}
  let outputPath
  const args = process.argv.slice(2)
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--backend' && args[index + 1]) {
      const value = args[++index]
      const separator = value.indexOf('=')
      if (separator < 1 || separator === value.length - 1) throw new Error('Expected --backend <name>=<cobertura.xml>')
      const name = value.slice(0, separator)
      if (Object.hasOwn(reports, name)) throw new Error(`Duplicate backend report: ${name}`)
      reports[name] = readFileSync(value.slice(separator + 1), 'utf8')
      continue
    }
    if (args[index] === '--output' && args[index + 1]) {
      if (outputPath) throw new Error('Output path was specified more than once')
      outputPath = args[++index]
      continue
    }
    throw new Error('Usage: zig-coverage-aggregate.mjs --backend quickjs=<xml> --backend quickjs_ng=<xml> --backend jsc=<xml> --output <xml>')
  }
  if (!outputPath) throw new Error('An output path is required')
  const result = mergeZigBackendReports(reports)
  writeFileSync(outputPath, result.report)
  delete result.report
  process.stdout.write(JSON.stringify(result) + '\n')
}

if (process.argv[1]?.endsWith('/zig-coverage-aggregate.mjs')) {
  try {
    runCli()
  } catch (error) {
    console.error(error.message)
    process.exitCode = 2
  }
}
