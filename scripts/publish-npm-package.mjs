import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const [path, expectedIntegrity] = process.argv.slice(2)
if (!path || !expectedIntegrity) throw new Error('Usage: publish-npm-package.mjs <package-tarball> <sha512-integrity>')
const tarball = resolve(path)
const integrity = `sha512-${createHash('sha512').update(await readFile(tarball)).digest('base64')}`
if (integrity !== expectedIntegrity) throw new Error(`Tarball integrity mismatch for ${tarball}`)

const manifest = JSON.parse(execFileSync('tar', ['-xOf', tarball, 'package/package.json'], { encoding: 'utf8' }))
const packageSpec = `${manifest.name}@${manifest.version}`
const npm = process.env.NPM ?? 'npm'
let publishedIntegrity

try {
  publishedIntegrity = JSON.parse(execFileSync(npm, ['view', packageSpec, 'dist.integrity', '--json', '--prefer-online'], { encoding: 'utf8' }))
} catch (error) {
  if (!String(error.stderr).includes('E404')) throw error
}

if (publishedIntegrity !== undefined) {
  if (publishedIntegrity !== integrity) {
    throw new Error(`${packageSpec} already exists with different content`)
  }
  console.log(`${packageSpec} already exists with matching integrity ${integrity}`)
} else {
  const args = ['publish', tarball, '--access', 'public']
  if (manifest.version.includes('-')) args.push('--tag', 'next')
  if (process.env.JSBAY_NPM_PUBLISH_DRY_RUN === 'true') args.push('--dry-run')
  execFileSync(npm, args, { stdio: 'inherit' })
}
