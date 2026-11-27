'use strict'

const assert = require('node:assert/strict')

const addonPath = process.env.JSBAY_NODE_ADDON
assert.ok(addonPath, 'JSBAY_NODE_ADDON must name the Node-API module')
assert.equal(process.platform, 'win32', 'this consumer verifies the Windows loopback transport')
assert.equal(typeof WebSocket, 'function', 'Node.js must provide the WebSocket client')

const { Engine } = require(addonPath)
const engine = Engine.create()
let socket
let inspectorRunning = false

function withTimeout(promise, label, milliseconds = 5000) {
  let timer
  const expiry = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds)
  })
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer))
}

function waitForOpen(webSocket) {
  return withTimeout(new Promise((resolve, reject) => {
    webSocket.addEventListener('open', resolve, { once: true })
    webSocket.addEventListener('error', () => reject(new Error('Inspector WebSocket failed to connect')), { once: true })
  }), 'Inspector WebSocket connection')
}

function sendCommand(webSocket, id, method, params) {
  return withTimeout(new Promise((resolve, reject) => {
    const onMessage = event => {
      let message
      try {
        message = JSON.parse(event.data)
      } catch (error) {
        cleanup()
        reject(error)
        return
      }
      if (message.id !== id) return
      cleanup()
      resolve(message)
    }
    const onError = () => {
      cleanup()
      reject(new Error(`Inspector WebSocket failed during ${method}`))
    }
    const cleanup = () => {
      webSocket.removeEventListener('message', onMessage)
      webSocket.removeEventListener('error', onError)
    }
    webSocket.addEventListener('message', onMessage)
    webSocket.addEventListener('error', onError, { once: true })
    webSocket.send(JSON.stringify({ id, method, params }))
  }), `Inspector ${method}`)
}

async function main() {
  const port = engine.inspectorStart(0)
  inspectorRunning = true
  assert.ok(Number.isInteger(port) && port > 0 && port <= 65535, 'inspectorStart(0) returns the selected port')

  const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(5000) })
  assert.equal(response.status, 200, 'the loopback target discovery endpoint responds')
  const targets = await response.json()
  assert.ok(Array.isArray(targets) && targets.length > 0, 'the discovery response contains an Inspector target')
  const target = targets[0]
  assert.equal(typeof target.webSocketDebuggerUrl, 'string')
  const webSocketUrl = new URL(target.webSocketDebuggerUrl)
  assert.equal(Number(webSocketUrl.port), port, 'the discovery URL uses the selected listener port')
  webSocketUrl.hostname = '127.0.0.1'

  socket = new WebSocket(webSocketUrl)
  await waitForOpen(socket)
  const enabled = await sendCommand(socket, 1, 'Runtime.enable', {})
  assert.equal(enabled.error, undefined, `Runtime.enable failed: ${JSON.stringify(enabled.error)}`)
  const reply = await sendCommand(socket, 2, 'Runtime.evaluate', {
    expression: '6 * 7',
    returnByValue: true,
  })
  assert.equal(reply.error, undefined, `Runtime.evaluate failed: ${JSON.stringify(reply.error)}`)
  assert.equal(reply.result?.result?.value, 42, 'CDP Runtime.evaluate returns the guest result')

  const closed = new Promise(resolve => socket.addEventListener('close', resolve, { once: true }))
  socket.close(1000, 'test complete')
  await withTimeout(closed, 'Inspector WebSocket close')
  socket = undefined

  engine.inspectorStop()
  inspectorRunning = false
  const restartedPort = engine.inspectorStart(0)
  inspectorRunning = true
  assert.ok(Number.isInteger(restartedPort) && restartedPort > 0, 'the Inspector listener can restart after stop')
  engine.inspectorStop()
  inspectorRunning = false
  console.log(`Windows Node Inspector loopback consumer passed on port ${port}`)
}

main().catch(error => {
  console.error(error && error.stack || error)
  process.exitCode = 1
}).finally(() => {
  if (socket && socket.readyState < WebSocket.CLOSING) socket.close()
  if (inspectorRunning) engine.inspectorStop()
  engine.close()
})
