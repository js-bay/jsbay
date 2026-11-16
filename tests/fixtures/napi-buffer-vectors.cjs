'use strict'

const constructors = new Map([
  ['Int8Array', Int8Array], ['Uint8Array', Uint8Array], ['Uint8ClampedArray', Uint8ClampedArray],
  ['Int16Array', Int16Array], ['Uint16Array', Uint16Array], ['Int32Array', Int32Array],
  ['Uint32Array', Uint32Array], ['Float32Array', Float32Array], ['Float64Array', Float64Array],
  ['BigInt64Array', BigInt64Array], ['BigUint64Array', BigUint64Array], ['DataView', DataView], ['Buffer', Buffer],
])

function validateVector(vector) {
  if (!vector || typeof vector !== 'object' || typeof vector.name !== 'string') throw new TypeError('Invalid buffer vector')
  if (vector.type !== 'ArrayBuffer' && !constructors.has(vector.type)) throw new TypeError('Unsupported buffer vector type')
  for (const bytes of [vector.bytes, vector.expected]) {
    if (!Array.isArray(bytes) || !Array.from(bytes).every(byte => Number.isInteger(byte) && byte >= 0 && byte <= 255)) throw new TypeError('Invalid buffer vector bytes')
  }
  if (!Number.isSafeInteger(vector.byteOffset) || vector.byteOffset < 0 || !Number.isSafeInteger(vector.length) || vector.length < 0) throw new TypeError('Invalid buffer vector window')
  const width = constructors.get(vector.type)?.BYTES_PER_ELEMENT || 1
  const byteLength = vector.length * width
  if (!Number.isSafeInteger(byteLength) || vector.byteOffset % width !== 0 || vector.byteOffset + byteLength > vector.bytes.length || vector.expected.length !== byteLength) throw new RangeError('Invalid buffer vector window')
  if (vector.type === 'ArrayBuffer' && (vector.byteOffset !== 0 || vector.length !== vector.bytes.length)) throw new RangeError('ArrayBuffer vector must cover its buffer')
}

function createHostVector(vector) {
  validateVector(vector)
  const bytes = Uint8Array.from(vector.bytes)
  const view = vector.type === 'ArrayBuffer' ? bytes.buffer
    : vector.type === 'Buffer' ? Buffer.from(bytes.buffer, vector.byteOffset, vector.length)
      : new (constructors.get(vector.type))(bytes.buffer, vector.byteOffset, vector.length)
  return { bytes, view }
}

// Fixture JSON crosses the native boundary as a string value, never as executable source text.
const guestVectorProgram = `(() => {
  const vector = JSON.parse(globalThis.__boundaryVectorJson);
  const constructors = new Map([
    ['Int8Array', Int8Array], ['Uint8Array', Uint8Array], ['Uint8ClampedArray', Uint8ClampedArray],
    ['Int16Array', Int16Array], ['Uint16Array', Uint16Array], ['Int32Array', Int32Array],
    ['Uint32Array', Uint32Array], ['Float32Array', Float32Array], ['Float64Array', Float64Array],
    ['BigInt64Array', BigInt64Array], ['BigUint64Array', BigUint64Array], ['DataView', DataView], ['Buffer', Uint8Array],
  ]);
  if (vector.type !== 'ArrayBuffer' && !constructors.has(vector.type)) throw new TypeError('Unsupported buffer vector type');
  const bytes = globalThis.__boundaryGuestBytes = Uint8Array.from(vector.bytes);
  return vector.type === 'ArrayBuffer' ? bytes.buffer
    : new (constructors.get(vector.type))(bytes.buffer, vector.byteOffset, vector.length);
})()`

module.exports = { validateVector, createHostVector, guestVectorProgram }
