import { execFileSync } from 'node:child_process'
import { readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'

const args = new Map()
for (let index = 2; index < process.argv.length; index += 2) {
  if (!process.argv[index]?.startsWith('--') || !process.argv[index + 1]) throw new Error('Expected --repo, --report, and --source-sha arguments')
  args.set(process.argv[index], process.argv[index + 1])
}

const repository = args.get('--repo')
const reportPath = args.get('--report')
const sourceSha = args.get('--source-sha')
if (!repository || !reportPath || !/^[0-9a-f]{40}$/.test(sourceSha ?? '')) throw new Error('Expected --repo, --report, and a full --source-sha')

const git = (arguments_, options = {}) => execFileSync('git', ['-C', repository, ...arguments_], { encoding: 'utf8', ...options }).trim()
const report = readFileSync(reportPath, 'utf8')
execFileSync(process.execPath, ['scripts/quality/zig-coverage-report.mjs'], { input: report, stdio: ['pipe', 'ignore', 'inherit'] })

const reportWithoutComments = report.replace(/<!--[\s\S]*?-->/g, ' ')
const root = reportWithoutComments.match(/<coverage\b([^>]*)>/)?.[1]
const attribute = name => root?.match(new RegExp(`(?:^|\\s)${name}\\s*=\\s*(["'])(\\d+)\\1`))?.[2]
const linesValid = Number(attribute('lines-valid'))
const linesCovered = Number(attribute('lines-covered'))
if (!Number.isSafeInteger(linesValid) || !Number.isSafeInteger(linesCovered) || linesValid <= 0 || linesCovered <= 0 || linesCovered > linesValid) throw new Error('Coverage report has invalid line counts')

const percentage = `${(Math.round((linesCovered / linesValid) * 1000) / 10).toFixed(1)}%`
const badge = `${JSON.stringify({ schemaVersion: 1, label: 'QuickJS-NG compiled line coverage', message: percentage, color: 'blue', sourceSha }, null, 2)}\n`
let completed = false
for (let attempt = 1; attempt <= 3; attempt += 1) {
  git(['fetch', '--no-tags', 'origin', 'main:refs/remotes/origin/main'])
  const mainSha = git(['rev-parse', 'refs/remotes/origin/main'])
  if (mainSha !== sourceSha) {
    console.log('Skipping stale coverage report because main has advanced')
    completed = true
    break
  }

  try {
    git(['fetch', '--no-tags', 'origin', 'refs/heads/coverage-badge:refs/remotes/origin/coverage-badge'])
  } catch {
    // A missing data branch is expected on its first publication.
  }
  const parent = (() => {
    try { return git(['rev-parse', 'refs/remotes/origin/coverage-badge']) } catch { return undefined }
  })()

  if (parent) {
    const previous = JSON.parse(git(['show', 'refs/remotes/origin/coverage-badge:coverage.json']))
    if (previous.sourceSha === sourceSha) {
      console.log('Coverage badge already records this source commit')
      completed = true
      break
    }
    execFileSync('git', ['-C', repository, 'merge-base', '--is-ancestor', previous.sourceSha, sourceSha], { encoding: 'utf8', stdio: 'ignore' })
  }

  const indexPath = `${tmpdir()}/jsbay-coverage-badge-index-${process.pid}`
  const env = { ...process.env, GIT_INDEX_FILE: indexPath }
  try {
    git(['read-tree', '--empty'], { env })
    const blob = git(['hash-object', '-w', '--stdin'], { env, input: badge })
    git(['update-index', '--add', '--cacheinfo', `100644,${blob},coverage.json`], { env })
    const tree = git(['write-tree'], { env })
    const commitArguments = ['commit-tree', tree]
    if (parent) commitArguments.push('-p', parent)
    commitArguments.push('-m', 'Update coverage badge')
    const commit = git(commitArguments, {
      env: {
        ...env,
        GIT_AUTHOR_NAME: 'github-actions[bot]',
        GIT_AUTHOR_EMAIL: '41898282+github-actions[bot]@users.noreply.github.com',
        GIT_COMMITTER_NAME: 'github-actions[bot]',
        GIT_COMMITTER_EMAIL: '41898282+github-actions[bot]@users.noreply.github.com',
      },
    })

    git(['fetch', '--no-tags', 'origin', 'main:refs/remotes/origin/main'])
    if (git(['rev-parse', 'refs/remotes/origin/main']) !== sourceSha) {
      console.log('Skipping stale coverage report because main advanced during publication')
      completed = true
      break
    }
    const lease = `--force-with-lease=refs/heads/coverage-badge:${parent ?? ''}`
    git(['push', lease, 'origin', `${commit}:refs/heads/coverage-badge`])
    console.log(`Published ${percentage} coverage for ${sourceSha}`)
    completed = true
    break
  } catch (error) {
    if (attempt === 3) throw error
  } finally {
    rmSync(indexPath, { force: true })
  }
}

if (!completed) throw new Error('Could not publish coverage badge after three concurrent update attempts')
