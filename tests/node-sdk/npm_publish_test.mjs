import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { once } from 'node:events'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const npm = process.env.NPM ?? 'npm'
const run = promisify(execFile)
const directory = await mkdtemp(join(tmpdir(), 'jsbay-npm-publish-'))
const methods = []
const manifest = { name: '@jsbay/quickjs', version: '0.2.0-rc.1' }
let storedIntegrity
const server = createServer((request, response) => {
  methods.push(request.method)
  if (storedIntegrity && request.method === 'GET') {
    response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({
      _id: manifest.name,
      name: manifest.name,
      'dist-tags': { next: manifest.version },
      versions: { [manifest.version]: { ...manifest, dist: { integrity: storedIntegrity } } },
    }))
  } else {
    response.writeHead(404).end('{}')
  }
})

try {
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const env = { ...process.env, NPM_CONFIG_REGISTRY: `http://127.0.0.1:${server.address().port}/`,
    NPM_CONFIG_CACHE: join(directory, 'cache'), JSBAY_NPM_PUBLISH_DRY_RUN: 'true' }
  await writeFile(join(directory, 'package.json'), JSON.stringify(manifest))
  const { stdout: packed } = await run(npm, ['pack', '--json'], { cwd: directory, env })
  const tarball = join(directory, JSON.parse(packed)[0].filename)
  const integrity = `sha512-${createHash('sha512').update(await readFile(tarball)).digest('base64')}`
  const publishScript = fileURLToPath(new URL('../../scripts/publish-npm-package.mjs', import.meta.url))
  const { stdout, stderr } = await run(process.execPath, [publishScript, tarball, integrity], { cwd: directory, env })
  assert.match(stdout, /\+ @jsbay\/quickjs@0\.2\.0-rc\.1/)
  assert.match(stderr, /with tag next/)
  assert(methods.includes('GET'), 'The registry should be checked for an existing version')
  storedIntegrity = integrity
  const replay = await run(process.execPath, [publishScript, tarball, integrity], { cwd: directory, env })
  assert.match(replay.stdout, /already exists with matching integrity/)
  storedIntegrity = 'sha512-published-other-content'
  await assert.rejects(run(process.execPath, [publishScript, tarball, integrity], { cwd: directory, env }), /already exists with different content/)
  await assert.rejects(run(process.execPath, [publishScript, tarball, 'sha512-invalid'], { cwd: directory, env }), /integrity mismatch/i)
  assert(methods.every((method) => method === 'GET'), 'A dry run must not modify the registry')
  console.log('npm prerelease and tarball integrity checks passed')
} finally {
  if (server.listening) await new Promise((resolve) => server.close(resolve))
  await rm(directory, { recursive: true, force: true })
}
