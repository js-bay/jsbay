let log = ''
for await (const chunk of process.stdin) log += chunk

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
process.stdout.write(JSON.stringify(result) + '\n')
