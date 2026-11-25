import assert from 'node:assert/strict'
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { test } from 'node:test'

const script = resolve('scripts/quality/publish-coverage-badge.mjs')
const validReport = (covered, valid = 10) => `<coverage lines-valid="${valid}" lines-covered="${covered}"><class filename="src/runtime.zig"><lines><line number="1" hits="1"/></lines></class></coverage>`

function repository() {
  const root = mkdtempSync(join(tmpdir(), 'jsbay-coverage-badge-'))
  const remote = join(root, 'remote.git')
  const checkout = join(root, 'checkout')
  mkdirSync(root, { recursive: true })
  execFileSync('git', ['init', '--bare', '--initial-branch=main', remote], { stdio: 'ignore' })
  execFileSync('git', ['clone', remote, checkout], { stdio: 'ignore' })
  execFileSync('git', ['-C', checkout, 'config', 'user.name', 'Coverage Test'])
  execFileSync('git', ['-C', checkout, 'config', 'user.email', 'coverage@example.com'])
  writeFileSync(join(checkout, 'source.txt'), 'one\n')
  execFileSync('git', ['-C', checkout, 'add', 'source.txt'])
  execFileSync('git', ['-C', checkout, 'commit', '-m', 'first source commit'], { stdio: 'ignore' })
  execFileSync('git', ['-C', checkout, 'push', 'origin', 'main'], { stdio: 'ignore' })
  return { root, remote, checkout, firstSha: execFileSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() }
}

function publish(repo, report, sourceSha) {
  return spawnSync(process.execPath, [script, '--repo', repo, '--report', report, '--source-sha', sourceSha], { encoding: 'utf8' })
}

function publishAsync(repo, report, sourceSha) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, [script, '--repo', repo, '--report', report, '--source-sha', sourceSha], { stdio: ['ignore', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk })
    child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk })
    child.on('close', status => resolve({ status, stdout, stderr }))
  })
}

function branchBadge(remote) {
  const result = execFileSync('git', ['--git-dir', remote, 'show', 'coverage-badge:coverage.json'], { encoding: 'utf8' })
  return JSON.parse(result)
}

test('publishes a validated coverage value on a data-only branch and advances it with main', t => {
  const state = repository()
  t.after(() => rmSync(state.root, { recursive: true, force: true }))
  const report = join(state.root, 'coverage.xml')
  writeFileSync(report, validReport(9))

  const first = publish(state.checkout, report, state.firstSha)
  assert.equal(first.status, 0, first.stderr)
  assert.deepEqual(branchBadge(state.remote), {
    schemaVersion: 1,
    label: 'QuickJS-NG compiled line coverage',
    message: '90.0%',
    color: 'blue',
    sourceSha: state.firstSha,
  })
  assert.deepEqual(execFileSync('git', ['--git-dir', state.remote, 'ls-tree', '--name-only', 'coverage-badge'], { encoding: 'utf8' }).trim().split('\n'), ['coverage.json'])

  writeFileSync(join(state.checkout, 'source.txt'), 'two\n')
  execFileSync('git', ['-C', state.checkout, 'add', 'source.txt'])
  execFileSync('git', ['-C', state.checkout, 'commit', '-m', 'second source commit'], { stdio: 'ignore' })
  execFileSync('git', ['-C', state.checkout, 'push', 'origin', 'main'], { stdio: 'ignore' })
  const secondSha = execFileSync('git', ['-C', state.checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
  writeFileSync(report, validReport(7))
  const second = publish(state.checkout, report, secondSha)
  assert.equal(second.status, 0, second.stderr)
  assert.equal(branchBadge(state.remote).message, '70.0%')
  assert.equal(branchBadge(state.remote).sourceSha, secondSha)
})

test('ignores an older source commit after main has advanced', t => {
  const state = repository()
  t.after(() => rmSync(state.root, { recursive: true, force: true }))
  const report = join(state.root, 'coverage.xml')
  writeFileSync(report, validReport(8))
  assert.equal(publish(state.checkout, report, state.firstSha).status, 0)
  const before = branchBadge(state.remote)

  writeFileSync(join(state.checkout, 'source.txt'), 'two\n')
  execFileSync('git', ['-C', state.checkout, 'add', 'source.txt'])
  execFileSync('git', ['-C', state.checkout, 'commit', '-m', 'second source commit'], { stdio: 'ignore' })
  execFileSync('git', ['-C', state.checkout, 'push', 'origin', 'main'], { stdio: 'ignore' })
  writeFileSync(report, validReport(1))
  const stale = publish(state.checkout, report, state.firstSha)
  assert.equal(stale.status, 0, stale.stderr)
  assert.match(stale.stdout, /Skipping stale coverage report/)
  assert.deepEqual(branchBadge(state.remote), before)
})

test('serializes concurrent first publications with a compare-and-swap push', async t => {
  const state = repository()
  t.after(() => rmSync(state.root, { recursive: true, force: true }))
  const secondCheckout = join(state.root, 'second-checkout')
  execFileSync('git', ['clone', state.remote, secondCheckout], { stdio: 'ignore' })
  const report = join(state.root, 'coverage.xml')
  writeFileSync(report, validReport(6))

  const results = await Promise.all([
    publishAsync(state.checkout, report, state.firstSha),
    publishAsync(secondCheckout, report, state.firstSha),
  ])
  assert.deepEqual(results.map(result => result.status), [0, 0], results.map(result => result.stderr).join('\n'))
  assert.equal(branchBadge(state.remote).sourceSha, state.firstSha)
  assert.equal(execFileSync('git', ['--git-dir', state.remote, 'rev-list', '--count', 'coverage-badge'], { encoding: 'utf8' }).trim(), '1')
})

test('skips an older run and publishes the newest source commit', async t => {
  const state = repository()
  t.after(() => rmSync(state.root, { recursive: true, force: true }))
  const oldCheckout = join(state.root, 'old-checkout')
  execFileSync('git', ['clone', state.remote, oldCheckout], { stdio: 'ignore' })

  writeFileSync(join(state.checkout, 'source.txt'), 'newer source\n')
  execFileSync('git', ['-C', state.checkout, 'add', 'source.txt'])
  execFileSync('git', ['-C', state.checkout, 'commit', '-m', 'newer source commit'], { stdio: 'ignore' })
  execFileSync('git', ['-C', state.checkout, 'push', 'origin', 'main'], { stdio: 'ignore' })
  const newestSha = execFileSync('git', ['-C', state.checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()

  const olderReport = join(state.root, 'older-coverage.xml')
  const newerReport = join(state.root, 'newer-coverage.xml')
  writeFileSync(olderReport, validReport(2))
  writeFileSync(newerReport, validReport(8))
  const [older, newer] = await Promise.all([
    publishAsync(oldCheckout, olderReport, state.firstSha),
    publishAsync(state.checkout, newerReport, newestSha),
  ])

  assert.equal(older.status, 0, older.stderr)
  assert.match(older.stdout, /Skipping stale coverage report/)
  assert.equal(newer.status, 0, newer.stderr)
  assert.equal(branchBadge(state.remote).sourceSha, newestSha)
  assert.equal(branchBadge(state.remote).message, '80.0%')
  assert.doesNotMatch(readFileSync(resolve('.github/workflows/coverage-badge.yml'), 'utf8'), /^concurrency:/m)
})

test('rejects an invalid report without changing the published branch', t => {
  const state = repository()
  t.after(() => rmSync(state.root, { recursive: true, force: true }))
  const report = join(state.root, 'coverage.xml')
  writeFileSync(report, validReport(8))
  assert.equal(publish(state.checkout, report, state.firstSha).status, 0)
  const before = branchBadge(state.remote)
  writeFileSync(report, '<coverage lines-valid="0" lines-covered="0"/>')
  const invalid = publish(state.checkout, report, state.firstSha)
  assert.notEqual(invalid.status, 0)
  assert.deepEqual(branchBadge(state.remote), before)
})

test('reads coverage counts from the real root after XML comments are removed', t => {
  const state = repository()
  t.after(() => rmSync(state.root, { recursive: true, force: true }))
  const report = join(state.root, 'coverage.xml')
  writeFileSync(report, `<!-- <coverage lines-valid="10" lines-covered="1"/> -->\n${validReport(9)}`)

  const result = publish(state.checkout, report, state.firstSha)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(branchBadge(state.remote).message, '90.0%')
})
