'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const vm = require('node:vm')
const vectors = require('./fixtures/napi-buffer-boundaries.json')
const { validateVector, createHostVector, guestVectorProgram } = require('./fixtures/napi-buffer-vectors.cjs')

for (const vector of vectors) {
  test(`buffer fixture data-only guest: ${vector.name}`, () => {
    const { bytes, view } = createHostVector(vector)
    if (vector.type === 'Buffer') assert.ok(Buffer.isBuffer(view))
    else assert.equal(Object.prototype.toString.call(view), `[object ${vector.type}]`)
    const hostCopy = view instanceof ArrayBuffer ? new Uint8Array(view) : new Uint8Array(view.buffer, view.byteOffset, view.byteLength)
    assert.deepEqual([...hostCopy], vector.expected)
    const context = vm.createContext({ __boundaryVectorJson: JSON.stringify(vector) })
    const guest = vm.runInContext(guestVectorProgram, context)
    const guestType = vector.type === 'Buffer' ? 'Uint8Array' : vector.type
    assert.equal(Object.prototype.toString.call(guest), `[object ${guestType}]`)
    const guestCopy = vector.type === 'ArrayBuffer' ? new Uint8Array(guest) : new Uint8Array(guest.buffer, guest.byteOffset, guest.byteLength)
    assert.deepEqual([...guestCopy], vector.expected)
    vm.runInContext('__boundaryGuestBytes.fill(254)', context)
    assert.ok(bytes.every((byte, index) => byte === vector.bytes[index]))
  })
}

test('unsupported constructor names and executable-looking types are data, not syntax', () => {
  for (const type of ['Function', 'constructor', '__proto__', 'MissingArray', 'Uint8Array(bytes.buffer); globalThis.injected = true; //']) {
    const vector = { ...vectors[0], type }
    assert.throws(() => validateVector(vector), /Unsupported buffer vector type/)
    const context = vm.createContext({ __boundaryVectorJson: JSON.stringify(vector) })
    assert.throws(() => vm.runInContext(guestVectorProgram, context), /Unsupported buffer vector type/)
    assert.equal(context.injected, undefined)
  }
})

test('reject malformed bytes, offsets, lengths, alignment and partial ArrayBuffers', () => {
  const base = vectors[0]
  for (const change of [
    { bytes: '1,2' }, { bytes: [0, 256] }, { bytes: [NaN] }, { bytes: Array(4) },
    { expected: [1, -1] }, { byteOffset: '1' }, { length: '2' },
    { byteOffset: '0);globalThis.injected=true;//' }, { length: '2);globalThis.injected=true;//' },
    { byteOffset: -1 }, { length: 0.5 }, { length: Infinity }, { length: Number.MAX_SAFE_INTEGER },
    { byteOffset: 3 }, { type: 'Int16Array', byteOffset: 1 },
    { type: 'ArrayBuffer', byteOffset: 1, length: 2 },
  ]) assert.throws(() => createHostVector({ ...base, ...change }))
})

test('executable-looking fixture names remain inert strings', () => {
  const vector = { ...vectors[0], name: '\"; globalThis.injected = true; //' }
  validateVector(vector)
  const context = vm.createContext({ __boundaryVectorJson: JSON.stringify(vector) })
  vm.runInContext(guestVectorProgram, context)
  assert.equal(context.injected, undefined)
})

test('numeric fields with executable-looking expressions never execute in the static program', () => {
  for (const field of ['byteOffset', 'length']) {
    const vector = { ...vectors[0], [field]: '(() => { globalThis.injected = true; return 0 })()' }
    assert.throws(() => createHostVector(vector), /Invalid buffer vector window/)
    const context = vm.createContext({ __boundaryVectorJson: JSON.stringify(vector) })
    vm.runInContext(guestVectorProgram, context)
    assert.equal(context.injected, undefined)
  }
})
