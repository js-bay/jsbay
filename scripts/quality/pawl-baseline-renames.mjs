import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, renameSync } from 'node:fs'
import { dirname, resolve, sep } from 'node:path'

const [root, base, baseline] = process.argv.slice(2)
if (!root || !base || !baseline) throw new Error('expected root, base, and baseline directory')

const records = execFileSync('git', ['diff', '--find-renames', '--no-relative', '--name-status', '-z', '--diff-filter=R', base], { cwd: root }).toString().split('\0')
const baseDir = resolve(baseline) + sep
for (let i = 0; i + 2 < records.length; i += 3) {
  const [status, from, to] = records.slice(i, i + 3)
  if (!/^R\d+$/.test(status) || !from || !to) throw new Error('invalid rename record')
  const source = resolve(baseDir, from)
  const destination = resolve(baseDir, to)
  if (!source.startsWith(baseDir) || !destination.startsWith(baseDir)) throw new Error('rename escapes baseline directory')
  if (!existsSync(source) || existsSync(destination)) continue
  mkdirSync(dirname(destination), { recursive: true })
  renameSync(source, destination)
}
