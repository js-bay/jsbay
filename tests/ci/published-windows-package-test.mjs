import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const classifier = resolve(root, 'tests/node-sdk/classify-published-windows-dependencies.mjs')
const version = '0.1.2-rc.3'
const legacy = {
  '@jsbay/quickjsnglinuxarm64': version,
  '@jsbay/quickjsnglinuxx64': version,
  '@jsbay/quickjsngmacosarm64': version,
  '@jsbay/quickjsngmacosx64': version,
}
const current = { ...legacy, '@jsbay/quickjsng-win32-x64': version }

function classify(dependencies, requestedVersion = version) {
  return spawnSync(process.execPath, [classifier, JSON.stringify(dependencies), requestedVersion], {
    cwd: root,
    encoding: 'utf8',
  })
}

test('published Windows dependency classifier accepts the exact separated package set', () => {
  const result = classify(current)
  assert.equal(result.status, 0, result.stderr)
})

test('published Windows dependency classifier skips only the complete legacy package set', () => {
  const result = classify(legacy)
  assert.equal(result.status, 3, result.stderr)
})

test('published Windows dependency classifier rejects incomplete or mismatched package metadata', () => {
  for (const dependencies of [
    { '@jsbay/quickjsnglinuxarm64': version },
    { ...legacy, '@jsbay/quickjsng-win32-x64': '0.1.2' },
    { ...legacy, '@jsbay/quickjsng-win32-x64': version, '@jsbay/quickjsnglinuxx64': '0.1.2' },
    {},
    { ...legacy, '@jsbay/quickjsng-win32-x64': version, '@jsbay/other': version },
  ]) {
    const result = classify(dependencies)
    assert.equal(result.status, 2, result.stderr)
  }
  assert.equal(classify(current, '0.1.2').status, 2)
})

test('published Windows npm install follows the shared CLI and registry configuration', async () => {
  const consumer = await readFile(resolve(root, 'tests/node-sdk/published-windows-package-consumer.mjs'), 'utf8')
  assert.match(consumer, /getNpmInvocation\(\)/)
  assert.match(consumer, /process\.env\.NPM_REGISTRY \|\| 'https:\/\/registry\.npmjs\.org'/)
  assert.match(consumer, /\.\.\.npm\.args[\s\S]*?--registry', registry/)
  assert.doesNotMatch(consumer, /node_modules['"],\s*'npm['"],\s*'bin['"]|const npmCli =/)
})

test('published Windows workflow keeps dependency classification statuses and public lockfile verification', async () => {
  const workflow = await readFile(resolve(root, '.github/workflows/npm-packages.yml'), 'utf8')
  const consumer = await readFile(resolve(root, 'tests/node-sdk/package_consumer.mjs'), 'utf8')
  assert.match(workflow, /classify-published-windows-dependencies\.mjs/)
  assert.match(workflow, /dependency_status" == 3/)
  assert.match(workflow, /dependency_status" != 0/)
  assert.match(consumer, /new URL\(locked\.resolved\)\.origin, 'https:\/\/registry\.npmjs\.org'/)
  assert.match(workflow, /NPM_REGISTRY:/)
})
