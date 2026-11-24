let xml = ''
for await (const chunk of process.stdin) xml += chunk
xml = xml.replace(/<!--[\s\S]*?-->/g, ' ')

function attributes(source) {
  return Object.fromEntries([...source.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)]
    .map(([, name, doubleQuoted, singleQuoted]) => [name, doubleQuoted ?? singleQuoted]))
}

const root = xml.match(/^\s*(?:<\?xml\b[^?]*\?>\s*)?(?:<!DOCTYPE\s+coverage\s+SYSTEM\s+[\'\"][^\'\"]+[\'\"]\s*>\s*)?<coverage\b([^>]*)>/)
if (!root) {
  console.error('Expected a Cobertura coverage root')
  process.exit(1)
}

const linesValidText = attributes(root[1])['lines-valid']
const linesValid = Number(linesValidText)
if (!/^\d+$/.test(linesValidText ?? '') || !Number.isSafeInteger(linesValid) || linesValid <= 0) {
  console.error('Cobertura report must contain a positive lines-valid count')
  process.exit(1)
}

const linesCoveredText = attributes(root[1])['lines-covered']
const linesCovered = Number(linesCoveredText)
if (!/^\d+$/.test(linesCoveredText ?? '') || !Number.isSafeInteger(linesCovered) || linesCovered <= 0 || linesCovered > linesValid) {
  console.error('Cobertura report must contain covered lines within its valid line count')
  process.exit(1)
}

const classes = [...xml.matchAll(/<class\b([^>]*)>([\s\S]*?)<\/class\s*>/g)]
for (const [, source] of classes) {
  const filename = attributes(source).filename ?? ''
  const parts = filename.split('/')
  if (!filename || filename.startsWith('/') || filename.includes('\\') || /^[A-Za-z]:/.test(filename) || parts.some(part => part === 'tests' || part === '.' || part === '..' || !part)) {
    console.error('Cobertura report contains a file outside the source scope')
    process.exit(1)
  }
}
const hasCoveredZigLine = classes.some(([, source, body]) => {
  if (!(attributes(source).filename ?? '').endsWith('.zig')) return false
  return [...body.matchAll(/<line\b([^>]*)\/?>/g)].some(([, line]) => Number(attributes(line).hits) > 0)
})
if (!hasCoveredZigLine) {
  console.error('Cobertura report must contain at least one Zig class with a covered line')
  process.exit(1)
}
