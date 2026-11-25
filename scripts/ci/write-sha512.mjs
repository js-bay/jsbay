import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { writeFile } from 'node:fs/promises'
import { basename } from 'node:path'

const [source, destination, filename] = process.argv.slice(2)
if (!source || !destination || !filename) {
  throw new Error('Usage: write-sha512.mjs <source> <destination> <filename>')
}

const hash = createHash('sha512')
for await (const chunk of createReadStream(source)) hash.update(chunk)
await writeFile(destination, `${hash.digest('hex')}  ${basename(filename)}\n`)
