import assert from 'node:assert/strict'

const [packagerUrl, appDir, outputDir, electronVersion] = process.argv.slice(2)
assert.ok(packagerUrl && appDir && outputDir && electronVersion, 'packager child requires its module URL and app paths')

const packageModule = await import(packagerUrl)
const packager = packageModule.packager ?? packageModule.default
assert.equal(typeof packager, 'function', 'Electron Packager must expose its packager function')
const bundles = await packager({
  dir: appDir,
  appName: 'JsBaySmoke',
  platform: 'win32',
  arch: 'x64',
  electronVersion,
  out: outputDir,
  overwrite: true,
  prune: false,
  asar: { unpack: '**/*.node' },
})
process.stdout.write(`JSBAY_ELECTRON_PACKAGER_RESULT=${JSON.stringify(bundles)}\n`)
