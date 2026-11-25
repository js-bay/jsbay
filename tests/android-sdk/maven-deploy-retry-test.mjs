import assert from 'node:assert/strict'
import { execFileSync, spawn } from 'node:child_process'
import { once } from 'node:events'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const [archive, version, backend] = process.argv.slice(2)
const artifacts = { quickjs: ['jsbay-quickjs', 'jsbayquickjs'], quickjs_ng: ['jsbay-quickjs-ng', 'jsbayquickjsng'] }
if (!archive || !version || !artifacts[backend]) {
  throw new Error('Usage: maven-deploy-retry-test.mjs <maven.zip> <version> <backend>')
}
const members = execFileSync('unzip', ['-Z1', archive], { encoding: 'utf8' }).split(/\r?\n/)
const artifact = artifacts[backend].find(candidate => members.includes(`io/jsbay/${candidate}/${version}/${candidate}-${version}.aar`))
if (!artifact) throw new Error(`Maven archive has no recognized ${backend} coordinate`)
const coordinate = `io/jsbay/${artifact}/${version}`
const filenames = ['.aar', '.pom', '.module', '-sources.jar'].map((ending) => `${artifact}-${version}${ending}`)
const files = new Map(filenames.map((filename) => [
  filename,
  execFileSync('unzip', ['-p', archive, `${coordinate}/${filename}`], { maxBuffer: 64 * 1024 * 1024 }),
]))
const work = await mkdtemp(join(tmpdir(), 'jsbay-maven-retry-'))
const repository = fileURLToPath(new URL('../../scripts/publish-android-maven.sh', import.meta.url))
const username = 'test-ci'
const password = 'test-password'
const authorization = `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`

let scenario
let record
const server = createServer((request, response) => {
  if (request.headers.authorization !== authorization || scenario === 'unauthorized') {
    response.writeHead(401).end()
    return
  }
  const prefix = `/packages/${coordinate}/`
  const filename = request.url.startsWith(prefix) ? request.url.slice(prefix.length) : ''
  const waitsForDeploy = scenario === 'missing' || scenario === 'incomplete-deploy'
  const isMissingModule = (scenario === 'partial' || scenario === 'incomplete-deploy') && filename.endsWith('.module')
  if (request.method !== 'GET' || !files.has(filename) || (waitsForDeploy && !existsSync(record)) || isMissingModule) {
    response.writeHead(404).end()
    return
  }
  if (scenario === 'conflict' && filename.endsWith('.pom')) {
    response.writeHead(200).end('different bytes')
    return
  }
  response.writeHead(200).end(files.get(filename))
})

try {
  const maven = join(work, 'mvn')
  await writeFile(maven, '#!/usr/bin/env node\nrequire("node:fs").appendFileSync(process.env.TEST_DEPLOY_RECORD, "deployed\\n")\n', { mode: 0o755 })
  server.listen(0, 'localhost')
  await once(server, 'listening')
  const url = `http://localhost:${server.address().port}/packages`

  async function publish(mode, shouldSucceed, shouldDeploy, expectedMessage) {
    scenario = mode
    record = join(work, mode)
    const child = spawn('bash', [repository, archive, version, backend, url, 'retry-test'], {
      env: {
        ...process.env,
        MVN: maven,
        MAVEN_REPOSITORY_USERNAME: username,
        MAVEN_REPOSITORY_PASSWORD: password,
        TEST_DEPLOY_RECORD: record,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const output = []
    child.stdout.on('data', (data) => output.push(data))
    child.stderr.on('data', (data) => output.push(data))
    const [status] = await once(child, 'close')
    const log = Buffer.concat(output).toString()
    assert.equal(status === 0, shouldSucceed, `${mode} returned ${status}\n${log}`)
    assert.equal(existsSync(record), shouldDeploy, `${mode} unexpected deployment\n${log}`)
    if (shouldDeploy) assert.equal(await readFile(record, 'utf8'), 'deployed\n')
    assert.match(log, expectedMessage)
    assert.ok(!log.includes(password), 'registry password appeared in output')
    console.log(`PASS: ${mode}`)
  }

  await publish('complete', true, false, /already published with matching contents/)
  await publish('missing', true, true, /Published io\.jsbay:/)
  await publish('incomplete-deploy', false, true, /Could not verify deployed Maven version/)
  await publish('partial', false, false, /incomplete Maven version/)
  await publish('conflict', false, false, /differs from staged/)
  await publish('unauthorized', false, false, /HTTP 401/)
} finally {
  if (server.listening) {
    server.close()
    await once(server, 'close')
  }
  await rm(work, { recursive: true, force: true })
}
