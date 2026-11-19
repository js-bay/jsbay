import { execFile } from 'node:child_process'
import { mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const registry = process.env.NPM_REGISTRY || 'https://registry.npmjs.org'
const [version, cacheRoot, userConfig, ...packages] = process.argv.slice(2)
const timeoutMs = Number(process.env.NPM_VISIBILITY_TIMEOUT_MS ?? 300_000)
const initialBackoffMs = Number(process.env.NPM_VISIBILITY_INITIAL_BACKOFF_MS ?? 1_000)
const maxBackoffMs = Number(process.env.NPM_VISIBILITY_MAX_BACKOFF_MS ?? 10_000)
const npm = process.env.NPM_CLI || 'npm'

if (!version || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) throw new Error('expected a valid exact npm package version')
if (!cacheRoot || !userConfig || packages.length !== 1 || !/^@jsbay\/[a-z0-9-]+$/.test(packages[0])) throw new Error('expected a cache directory and one @jsbay main package name')
if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) throw new Error('NPM_VISIBILITY_TIMEOUT_MS must be a positive integer')
if (!Number.isSafeInteger(initialBackoffMs) || initialBackoffMs <= 0 || !Number.isSafeInteger(maxBackoffMs) || maxBackoffMs < initialBackoffMs) throw new Error('npm visibility backoff values must be positive integers and max must be at least initial')

const cache = resolve(cacheRoot)
await mkdir(cache, { recursive: true })
const deadline = Date.now() + timeoutMs
console.log(`Waiting for exact npm package versions until ${new Date(deadline).toISOString()}`)

const [mainPackage] = packages
const mainManifest = await waitForPackage(mainPackage)
const optionalDependencies = mainManifest?.optionalDependencies
if (!optionalDependencies || typeof optionalDependencies !== 'object' || Array.isArray(optionalDependencies) || Object.keys(optionalDependencies).length === 0) throw new Error(`${mainPackage}@${version} does not declare optional platform packages`)
for (const [packageName, dependencyVersion] of Object.entries(optionalDependencies)) {
  if (!/^@jsbay\/[a-z0-9-]+$/.test(packageName) || dependencyVersion !== version) throw new Error(`${mainPackage}@${version} declares unsupported optional dependency ${packageName}@${dependencyVersion}; expected an @jsbay package at ${version}`)
  await waitForPackage(packageName)
}

async function waitForPackage(packageName) {
  let attempt = 0
  while (true) {
    const remainingMs = deadline - Date.now()
    if (remainingMs <= 0) throw new Error(`npm visibility deadline expired before ${packageName}@${version} became available`)

    let result
    let failure
    try {
      const query = packageName === mainPackage ? ['view', `${packageName}@${version}`, '--json'] : ['view', `${packageName}@${version}`, 'version', '--json']
      result = await execFileAsync(npm, [
        ...query,
        '--registry', registry,
        '--userconfig', userConfig,
        '--cache', cache,
        '--prefer-online',
        '--fetch-retries=0',
        `--fetch-timeout=${Math.max(1, remainingMs)}`,
      ], { timeout: remainingMs, maxBuffer: 1024 * 1024, encoding: 'utf8' })
    } catch (error) {
      failure = error
    }

    if (!failure) {
      let visibleVersion
      try {
        visibleVersion = JSON.parse(result.stdout)
      } catch (error) {
        throw new Error(`npm view returned invalid version data for ${packageName}@${version}: ${error.message}`)
      }
      const resolvedVersion = typeof visibleVersion === 'string' ? visibleVersion : visibleVersion?.version
      if (resolvedVersion !== version) throw new Error(`npm view returned ${JSON.stringify(resolvedVersion)}; expected exact version ${version} for ${packageName}`)
      console.log(`${packageName}@${version} is visible`)
      return visibleVersion
    }

    const stdout = failure.stdout ?? ''
    const stderr = failure.stderr ?? ''
    const output = `${stdout}\n${stderr}\n${failure.message ?? ''}`
    const structuredError = parseStructuredError(stdout)
    const structuredCode = structuredError?.code
    const structuredDetails = `${structuredError?.summary ?? ''}\n${structuredError?.detail ?? ''}`
    const legacyOutput = `${stdout}\n${stderr}`
    const code = ['ETARGET', 'E404'].includes(structuredCode)
      ? structuredCode
      : legacyOutput.match(/npm error code (ETARGET|E404)\b/)?.[1]
    const locator = `${packageName}@${version}`
    const identifiesTarget = structuredDetails.includes(locator) || legacyOutput.includes(locator)
    if (!code || !identifiesTarget) {
      if (Date.now() >= deadline) throw new Error(`npm visibility deadline expired while checking ${locator}; last check failed outside exact-version visibility errors:\n${output}`)
      throw new Error(`npm visibility check failed for ${locator} without an exact-version ETARGET/E404 response:\n${output}`)
    }

    const remaining = deadline - Date.now()
    if (remaining <= 0) throw new Error(`npm visibility deadline expired while waiting for ${locator}; last response was ${code}:\n${output}`)
    const delayMs = Math.min(maxBackoffMs, initialBackoffMs * (2 ** Math.min(attempt, 20)), remaining)
    attempt += 1
    const retryAt = new Date(Date.now() + delayMs).toISOString()
    console.warn(`${locator} is not visible yet (${code}); retry ${attempt} at ${retryAt}, deadline ${new Date(deadline).toISOString()}`)
    if (delayMs > 0) await new Promise((resolveDelay) => setTimeout(resolveDelay, delayMs))
  }
}

function parseStructuredError(stdout) {
  try {
    const parsed = JSON.parse(stdout)
    return parsed?.error && typeof parsed.error === 'object' ? parsed.error : undefined
  } catch {
    return undefined
  }
}
