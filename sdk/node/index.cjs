'use strict'

const { join } = require('node:path')

const addon = process.env.JSBAY_NODE_ADDON || join(__dirname, 'build', 'jsbay_node.node')
module.exports = require(addon)
