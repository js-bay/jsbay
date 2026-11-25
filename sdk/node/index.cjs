'use strict'

const { join } = require('node:path')

if (process.env.JSBAY_NODE_ADDON) {
  module.exports = require(process.env.JSBAY_NODE_ADDON)
} else {
  const sourceAddon = join(__dirname, 'build', 'jsbay_node.node')
  try {
    module.exports = require(sourceAddon)
  } catch (error) {
    if (error.code !== 'MODULE_NOT_FOUND') throw error
    const manifest = require('./package.json')
    const backend = manifest.jsbayBackend
    if (!['quickjs', 'quickjsng', 'jsc'].includes(backend)) throw error
    const platform = process.platform === 'darwin' ? 'macos' : process.platform
    const arch = process.arch
    const binaryPackage = `@jsbay/${backend}-${platform}-${arch}`
    try {
      module.exports = require(binaryPackage)
    } catch (binaryError) {
      if (binaryError.code !== 'MODULE_NOT_FOUND') throw binaryError
      throw new Error(`No prebuilt JsBay addon is available for ${backend} on ${process.platform}-${arch}`, { cause: binaryError })
    }
  }
}
