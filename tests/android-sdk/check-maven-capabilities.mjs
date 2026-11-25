import { readFile } from 'node:fs/promises'

const [moduleFile, primaryName, legacyName, version] = process.argv.slice(2)
if (!moduleFile || !primaryName || !legacyName || !version || process.argv.length !== 6) {
  throw new Error('usage: check-maven-capabilities.mjs <module-file> <primary-artifact> <legacy-artifact> <version>')
}

const metadata = JSON.parse(await readFile(moduleFile, 'utf8'))
const variants = metadata.variants ?? []
for (const usage of ['java-api', 'java-runtime']) {
  const libraryVariants = variants.filter(variant =>
    variant.attributes?.['org.gradle.category'] === 'library' &&
    variant.attributes?.['org.gradle.usage'] === usage
  )
  if (libraryVariants.length === 0) throw new Error(`Gradle module metadata has no library ${usage} variant`)
  for (const variant of libraryVariants) {
    for (const name of [primaryName, legacyName]) {
      if (!variant.capabilities?.some(capability => capability.group === 'io.jsbay' && capability.name === name && capability.version === version)) {
        throw new Error(`${variant.name} does not declare capability io.jsbay:${name}:${version}`)
      }
    }
  }
}
