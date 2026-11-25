import { readFile } from 'node:fs/promises'

const [logFile, primaryName, legacyName, version] = process.argv.slice(2)
if (!logFile || !primaryName || !legacyName || !version || process.argv.length !== 6) {
  throw new Error('usage: check-maven-capability-conflict.mjs <gradle-log> <primary-artifact> <legacy-artifact> <version>')
}

const log = await readFile(logFile, 'utf8')
const primaryCoordinate = `io.jsbay:${primaryName}:${version}`
const legacyCoordinate = `io.jsbay:${legacyName}:${version}`
const conflictPrefix = `Cannot select module with conflict on capability '${legacyCoordinate}' also provided by [`
const conflictLines = log.split(/\r?\n/).filter(line => line.includes(conflictPrefix))
const bothRequestedCoordinatesFailed = log.includes(`Could not resolve ${primaryCoordinate}.`) &&
  log.includes(`Could not resolve ${legacyCoordinate}.`)
const newCoordinateProvidesLegacyCapability = conflictLines.some(line => line.includes(`[${primaryCoordinate}(`))
const legacyCoordinateProvidesLegacyCapability = conflictLines.some(line => line.includes(`[${legacyCoordinate}(`))

if (!bothRequestedCoordinatesFailed || !newCoordinateProvidesLegacyCapability || !legacyCoordinateProvidesLegacyCapability) {
  throw new Error(`Gradle did not report both ${primaryCoordinate} and ${legacyCoordinate} rejected for the shared capability ${legacyCoordinate}`)
}
