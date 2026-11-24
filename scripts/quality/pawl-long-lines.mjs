import { spawnSync } from 'node:child_process'

const result = spawnSync(process.env.PAWL || 'pawl', ['measure', '-c', 'pawl.length.yaml'], { encoding: 'utf8' })
if (result.stderr) process.stderr.write(result.stderr)
if (result.error || result.status !== 0) {
  if (result.error) console.error(result.error.message)
  process.exit(2)
}
const metrics = JSON.parse(result.stdout).metrics
const files = Object.assign({}, ...Object.values(metrics).map(metric => metric.breakdown || {}))
const value = Object.values(files).reduce((sum, lines) => sum + lines, 0)
process.stdout.write(JSON.stringify({ value, unit: 'lines in files over the limit', breakdown: files }) + '\n')
