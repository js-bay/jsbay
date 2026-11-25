const [dependenciesJson, version, ...extra] = process.argv.slice(2)
if (!dependenciesJson || !version || extra.length || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  process.stderr.write('expected optionalDependencies JSON and an exact package version\n')
  process.exit(2)
}

let dependencies
try {
  dependencies = JSON.parse(dependenciesJson)
} catch {
  process.stderr.write('optionalDependencies must be valid JSON\n')
  process.exit(2)
}
if (!dependencies || typeof dependencies !== 'object' || Array.isArray(dependencies)) {
  process.stderr.write('optionalDependencies must be an object\n')
  process.exit(2)
}

const legacy = [
  '@jsbay/quickjsnglinuxarm64',
  '@jsbay/quickjsnglinuxx64',
  '@jsbay/quickjsngmacosarm64',
  '@jsbay/quickjsngmacosx64',
].sort()
const current = [...legacy, '@jsbay/quickjsng-win32-x64'].sort()
const names = Object.keys(dependencies).sort()
const hasExactVersions = names.every(name => dependencies[name] === version)

if (JSON.stringify(names) === JSON.stringify(current) && hasExactVersions) process.exit(0)
if (JSON.stringify(names) === JSON.stringify(legacy) && hasExactVersions) process.exit(3)
process.stderr.write(`optionalDependencies do not match a supported Windows package set for ${version}\n`)
process.exit(2)
