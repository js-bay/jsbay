import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { copyFileSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { test } from 'node:test'

const script = resolve('scripts/quality/pawl-ratchet.sh')
const adapter = resolve('scripts/quality/pawl-long-lines.mjs')
const pawl = process.env.PAWL || 'pawl'
const config = `snapshot: .pawl-ratchet.snapshot.json
dimensions:
  - id: long-files
    title: Long files
    direction: lower-is-better
    gate: per-file-count
    command: node scripts/quality/pawl-long-lines.mjs
`
const sourceConfig = `dimensions:
  - id: zig-long-files
    title: Long files
    direction: lower-is-better
    builtin: file-length
    options:
      threshold: 3
      include: ["src/**/*.zig"]
      min_files: 1
`

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'jsbay-pawl-ratchet-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const git = (...args) => execFileSync('git', args, { cwd: dir, stdio: 'pipe' })
  git('init', '-q')
  git('config', 'user.name', 'Test')
  git('config', 'user.email', 'test@example.invalid')
  mkdirSync(join(dir, 'src'))
  mkdirSync(join(dir, 'scripts', 'quality'), { recursive: true })
  copyFileSync(adapter, join(dir, 'scripts', 'quality', 'pawl-long-lines.mjs'))
  writeFileSync(join(dir, 'src', 'long.zig'), 'a\nb\nc\nd\n')
  writeFileSync(join(dir, 'src', 'short.zig'), 'a\nb\n')
  writeFileSync(join(dir, 'pawl.ratchet.yaml'), config)
  writeFileSync(join(dir, 'pawl.length.yaml'), sourceConfig)
  git('add', '.')
  git('commit', '-qm', 'baseline')
  const base = git('rev-parse', 'HEAD').toString().trim()
  const check = (ref = base) => spawnSync('bash', [script, ref], { cwd: dir, env: { ...process.env, PAWL: pawl }, encoding: 'utf8' })
  return { dir, check, git }
}

test('unchanged source passes without writing a snapshot into the repository', (t) => {
  const { dir, check } = fixture(t)
  const result = check()
  assert.equal(result.status, 0, result.stderr + result.stdout)
  const verdict = JSON.parse(result.stdout)
  assert.equal(verdict.exit_code, 0)
  assert.equal(readFileSync(join(dir, 'src', 'long.zig'), 'utf8'), 'a\nb\nc\nd\n')
  assert.throws(() => readFileSync(join(dir, '.pawl-ratchet.snapshot.json')))
})

test('growth of an already-long file is a regression', (t) => {
  const { dir, check } = fixture(t)
  writeFileSync(join(dir, 'src', 'long.zig'), 'a\nb\nc\nd\ne\n')
  const result = check()
  assert.equal(result.status, 1, result.stderr + result.stdout)
  assert.equal(JSON.parse(result.stdout).failure_class, 'regression')
})

test('a new oversized file is a regression', (t) => {
  const { dir, check } = fixture(t)
  writeFileSync(join(dir, 'src', 'new.zig'), 'a\nb\nc\nd\n')
  const result = check()
  assert.equal(result.status, 1, result.stderr + result.stdout)
  assert.equal(JSON.parse(result.stdout).failure_class, 'regression')
})

test('a new long file cannot be hidden by deleting another', (t) => {
  const { dir, check } = fixture(t)
  rmSync(join(dir, 'src', 'long.zig'))
  writeFileSync(join(dir, 'src', 'new.zig'), 'w\nx\ny\nz\n')
  const result = check()
  assert.equal(result.status, 1, result.stderr + result.stdout)
  assert.equal(JSON.parse(result.stdout).failure_class, 'regression')
})

test('a pure tracked rename does not create a regression', (t) => {
  const { check, git } = fixture(t)
  git('mv', 'src/long.zig', 'src/renamed.zig')
  const result = check()
  assert.equal(result.status, 0, result.stderr + result.stdout)
})

test('a renamed long file that grows is a regression', (t) => {
  const { dir, check, git } = fixture(t)
  git('mv', 'src/long.zig', 'src/renamed.zig')
  writeFileSync(join(dir, 'src', 'renamed.zig'), 'a\nb\nc\nd\ne\n')
  const result = check()
  assert.equal(result.status, 1, result.stderr + result.stdout)
  assert.equal(JSON.parse(result.stdout).failure_class, 'regression')
})

test('changing the measurement definition fails closed', (t) => {
  const { dir, check } = fixture(t)
  writeFileSync(join(dir, 'pawl.length.yaml'), sourceConfig.replace('threshold: 3', 'threshold: 100'))
  const result = check()
  assert.equal(result.status, 2, result.stderr + result.stdout)
})

test('changing the measurement adapter fails closed', (t) => {
  const { dir, check } = fixture(t)
  writeFileSync(join(dir, 'scripts', 'quality', 'pawl-long-lines.mjs'), 'process.stdout.write("{}")\n')
  const result = check()
  assert.equal(result.status, 2, result.stderr + result.stdout)
})

test('a missing base fails instead of accepting an empty baseline', (t) => {
  const { check } = fixture(t)
  const result = check('no-such-ref')
  assert.notEqual(result.status, 0)
})

test('a scan with no source files is a measurement failure', (t) => {
  const { dir, check } = fixture(t)
  rmSync(join(dir, 'src', 'long.zig'))
  rmSync(join(dir, 'src', 'short.zig'))
  const result = check()
  assert.equal(result.status, 2, result.stderr + result.stdout)
})
