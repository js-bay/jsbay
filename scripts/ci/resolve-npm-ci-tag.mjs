import { appendFile, readFile } from 'node:fs/promises'

const source = await readFile('build.zig.zon', 'utf8')
const version = source.match(/^\s*\.version\s*=\s*"([^"\s]+)"/m)?.[1]
if (!version || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error('build.zig.zon must declare a semantic version')
}
if (!process.env.GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT is required')
await appendFile(process.env.GITHUB_OUTPUT, `tag=v${version}\n`)
