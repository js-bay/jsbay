import assert from 'node:assert/strict'
import { createElectronPackagerOptions } from './electron-packager-options.mjs'

const [packagerUrl, appDir, outputDir, electronVersion] = process.argv.slice(2)
assert.ok(packagerUrl && appDir && outputDir && electronVersion, 'packager child requires its module URL and app paths')

const packageModule = await import(packagerUrl)
const packager = packageModule.packager ?? packageModule.default
assert.equal(typeof packager, 'function', 'Electron Packager must expose its packager function')
const bundles = await packager(createElectronPackagerOptions(appDir, outputDir, electronVersion))
process.stdout.write(`JSBAY_ELECTRON_PACKAGER_RESULT=${JSON.stringify(bundles)}\n`)
