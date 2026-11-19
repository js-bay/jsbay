import assert from 'node:assert/strict'
import { execFile, execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const [mainTarball, platformTarball, backend] = process.argv.slice(2)
assert(mainTarball && platformTarball && backend, 'Pass both package tarballs and the expected backend')
const npm = process.env.NPM ?? 'npm'
const run = promisify(execFile)
const directory = await mkdtemp(join(tmpdir(), 'jsbay-npm-consumer-'))
const server = createServer()

async function readPackage(tarball) {
  const body = await readFile(tarball)
  const files = new Set(execFileSync('tar', ['-tf', tarball], { encoding: 'utf8' }).trimEnd().split('\n'))
  assert(files.has('package/LICENSE') && files.has('package/THIRD_PARTY_NOTICES.md'), `${tarball} must include legal notices`)
  const manifest = JSON.parse(execFileSync('tar', ['-xOf', tarball, 'package/package.json'], { encoding: 'utf8' }))
  const integrity = `sha512-${createHash('sha512').update(body).digest('base64')}`
  return { body, files, manifest, integrity }
}

try {
  const main = await readPackage(mainTarball)
  const platform = await readPackage(platformTarball)
  const hostPlatform = process.platform === 'darwin' ? 'macos' : process.platform
  assert.equal(main.manifest.name, `@jsbay/${backend}`)
  assert.equal(main.manifest.jsbayBackend, backend)
  assert(main.files.has('package/index.d.ts'))
  assert.equal(platform.manifest.name, `@jsbay/${backend}${hostPlatform}${process.arch}`)
  assert.equal(platform.manifest.version, main.manifest.version)
  assert.equal(main.manifest.optionalDependencies[platform.manifest.name], platform.manifest.version)

  const served = new Set()
  server.on('request', (request, response) => {
    const pathname = decodeURIComponent(request.url)
    for (const [key, packaged] of [['main', main], ['platform', platform]]) {
      const { manifest, integrity, body } = packaged
      if (pathname === `/${key}.tgz`) {
        served.add(key)
        response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': body.length })
        response.end(body)
        return
      }
      if (pathname === `/${manifest.name}`) {
        const dist = { tarball: `${registry}${key}.tgz`, integrity }
        response.writeHead(200, { 'Content-Type': 'application/json' })
        response.end(JSON.stringify({
          name: manifest.name,
          'dist-tags': { latest: manifest.version },
          versions: { [manifest.version]: { ...manifest, dist } },
        }))
        return
      }
    }
    response.writeHead(404).end('{}')
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const registry = `http://127.0.0.1:${server.address().port}/`
  const packageFile = join(directory, 'package.json')
  await writeFile(packageFile, '{"name":"jsbay-consumer","private":true}\n')
  await run(npm, ['install', '--registry', registry, '--cache', join(directory, 'cache'), '--include=optional',
    '--ignore-scripts', '--no-audit', '--no-fund', '--no-package-lock', `${main.manifest.name}@${main.manifest.version}`], { cwd: directory })
  assert.deepEqual([...served].sort(), ['main', 'platform'])

  const addonPath = join(directory, 'node_modules', platform.manifest.name, 'jsbay_node.node')
  const expectedAddon = execFileSync('tar', ['-xOf', platformTarball, 'package/jsbay_node.node'], { maxBuffer: 64 * 1024 * 1024 })
  assert.deepEqual(await readFile(addonPath), expectedAddon)
  const env = { ...process.env, JSBAY_NODE_PACKAGE_ROOT: packageFile, JSBAY_NODE_PACKAGE: main.manifest.name }
  delete env.JSBAY_NODE_ADDON
  const consumer = fileURLToPath(new URL('./package_consumer.mjs', import.meta.url))
  const { stdout } = await run(process.execPath, [consumer], { env })
  process.stdout.write(stdout)
  console.log(`${main.manifest.name} ${main.integrity}`)
  console.log(`${platform.manifest.name} ${platform.integrity}`)
} finally {
  if (server.listening) await new Promise((resolve) => server.close(resolve))
  await rm(directory, { recursive: true, force: true })
}
