let log = ''
for await (const chunk of process.stdin) log += chunk

const noSkips = process.argv.length === 3 && process.argv[2] === '--no-skips'
if (process.argv.length > 2 && !noSkips) {
  console.error('Usage: zig-coverage-summary.mjs [--no-skips]')
  process.exit(2)
}

const failedLines = log.split(/\r?\n/).filter(line =>
  /^\s*(?:(?:thread\s+\d+\s+)?panic:|error:|FAIL(?:ED)?\b)/i.test(line) ||
  /^\s*\d+\/\d+\s+.*\.\.\.(?:FAIL|PANIC)\s*$/i.test(line),
)
if (failedLines.length > 0) {
  console.error('Zig test output contains a panic or failed test')
  process.exit(1)
}

const summaries = [...log.matchAll(/^(?:(\d+) passed; (\d+) skipped; (\d+) failed\.|All (\d+) tests? passed\.)\s*$/gm)]
if (summaries.length !== 1) {
  console.error('Expected one complete Zig test summary')
  process.exit(2)
}
const [, passed, skipped, failed, allPassed] = summaries[0]
const result = allPassed === undefined
  ? { passed: Number(passed), skipped: Number(skipped), failed: Number(failed) }
  : { passed: Number(allPassed), skipped: 0, failed: 0 }
if (result.passed === 0 || result.failed !== 0) {
  console.error('Zig tests did not pass under coverage')
  process.exit(1)
}
if (noSkips) {
  const lines = log.split(/\r?\n/)
  const headers = []
  for (let index = 0; index < lines.length; index++) {
    const match = lines[index].match(/^\s*(\d+)\/(\d+)\s+.+$/)
    if (match) headers.push({ line: index, index: Number(match[1]), total: Number(match[2]) })
  }
  const total = result.passed + result.skipped + result.failed
  const statuses = { OK: 0, SKIP: 0, FAIL: 0 }
  for (let index = 0; index < headers.length; index++) {
    const header = headers[index]
    if (header.total !== total) {
      console.error('Zig test output has inconsistent result totals')
      process.exit(1)
    }
    const end = headers[index + 1]?.line ?? lines.length
    const segment = lines.slice(header.line, end)
    const marks = []
    const inlineStatus = segment[0].match(/\.\.\.(OK|SKIP|FAIL)\s*$/)
    if (inlineStatus) marks.push(inlineStatus[1])
    for (const line of segment.slice(1)) {
      const status = line.match(/^\s*(OK|SKIP|FAIL)\s*$/)
      if (status) marks.push(status[1])
    }
    const resultStatus = marks.at(-1)
    if (!resultStatus) {
      console.error('Zig test output is incomplete or disagrees with its summary')
      process.exit(1)
    }
    statuses[resultStatus]++
    if (header.index !== index + 1) {
      console.error('Zig test output is incomplete or out of order')
      process.exit(1)
    }
  }
  if (result.skipped !== 0 || statuses.SKIP !== 0) {
    console.error('Zig package tests must not skip tests under coverage')
    process.exit(1)
  }
  if (headers.length !== total || statuses.OK !== result.passed || statuses.FAIL !== result.failed) {
    console.error('Zig test output is incomplete or disagrees with its summary')
    process.exit(1)
  }
}
process.stdout.write(JSON.stringify(result) + '\n')
