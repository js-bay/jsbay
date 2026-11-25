import { cp, mkdir, readFile, rm } from 'node:fs/promises'
import { join, resolve } from 'node:path'

export async function extractPackage(tarball, destination, run) {
  const archive = resolve(tarball)
  const target = resolve(destination)
  const stagedArchive = join(target, '.jsbay-package.tgz')
  await mkdir(target, { recursive: true })
  try {
    await cp(archive, stagedArchive)
    await run('tar', ['-xzf', '.jsbay-package.tgz', '--strip-components=1'], { cwd: target })
    return JSON.parse(await readFile(join(target, 'package.json'), 'utf8'))
  } finally {
    await rm(stagedArchive, { force: true })
  }
}
