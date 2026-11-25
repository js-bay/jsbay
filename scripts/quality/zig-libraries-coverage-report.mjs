import { readFileSync } from 'node:fs'

const packageNames = new Set([
  'bytecode_cache',
  'cmph',
  'commonjs',
  'hyper_box',
  'inspector',
  'inspector_transport',
  'js_event_loop',
  'simd_utf',
  'zev',
])

const xml = readFileSync(0, 'utf8').replace(/<!--[\s\S]*?-->/g, ' ')
const coveredPackages = new Set()
const classes = [...xml.matchAll(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g)]
const filenames = new Set()

for (const [, source] of classes) {
  const filename = source.match(/\bfilename\s*=\s*(?:"([^"]*)"|'([^']*)')/)?.slice(1).find(Boolean) ?? ''
  const parts = filename.split('/')
  const basename = parts.at(-1) ?? ''
  if (!filename || !filename.endsWith('.zig') || filename.startsWith('/') || filename.includes('\\') || parts.some(part => !part || part === '.' || part === '..')) {
    console.error('Library coverage report contains an unsafe source path')
    process.exit(1)
  }
  if (basename.startsWith('test') || basename.endsWith('_tests.zig') || parts.includes('tests')) {
    console.error('Library coverage report includes test source: ' + filename)
    process.exit(1)
  }
  if (!packageNames.has(parts[0])) {
    console.error('Library coverage source is outside the package set: ' + filename)
    process.exit(1)
  }
  filenames.add(filename)
  coveredPackages.add(parts[0])
}

if (classes.length === 0 || filenames.size !== classes.length) {
  console.error('Library coverage report must contain unique implementation files')
  process.exit(1)
}
const missingPackages = [...packageNames].filter(name => !coveredPackages.has(name))
if (missingPackages.length > 0) {
  console.error('Library coverage report is missing package coverage: ' + missingPackages.join(', '))
  process.exit(1)
}
