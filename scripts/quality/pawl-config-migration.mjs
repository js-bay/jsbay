import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'

const migrations = new Map([
  ['pawl.length.yaml', ['a416c601ba9270fdbdad3c2820c4785b5d632f8d5d11fe12b53117d34f6c61d3', 'aea4068098e49ea5894e543f40a8b159bdaa2674f98be2be5402291bb05561f6']],
  ['scripts/quality/pawl-ratchet.sh', ['0427823703b7540058560a00855774bc31172885acbbf71d0e7199fadda29e6f', 'b4807e5498594725dad9aef437c01058c221aeaa26feecb61a2ff7c765b04b81']],
])

const [definition, basePath, currentPath] = process.argv.slice(2)
const allowedHashes = migrations.get(definition)
if (!allowedHashes || !basePath || !currentPath) process.exit(1)

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

if (sha256(basePath) === allowedHashes[0] && sha256(currentPath) === allowedHashes[1]) process.exit(0)
process.exit(1)
