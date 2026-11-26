'use strict'

const assert = require('node:assert/strict')
const addon = require('../../sdk/node')

function statusIs(status) {
  return error => error && error.status === status
}

function stringConversionRejectsReentrantClose() {
  const engineClose = addon.Engine.create()
  const engineCloseValue = engineClose.evaluateValue('({ toString() { closeFromToString(); return "ok" } })')
  engineClose.bind('closeFromToString', () => engineClose.close())
  assert.throws(() => engineCloseValue.toString(), statusIs(4), 'toString rejects an Engine closed by guest conversion')
  engineCloseValue.close()
  engineClose.close()

  const valueCloseEngine = addon.Engine.create()
  const valueCloseValue = valueCloseEngine.evaluateValue('({ toString() { closeValueFromToString(); return "ok" } })')
  valueCloseEngine.bind('closeValueFromToString', () => valueCloseValue.close())
  assert.throws(() => valueCloseValue.toString(), statusIs(5), 'toString rejects a Value closed by guest conversion')
  assert.equal(valueCloseEngine.evaluate('40 + 2'), 42)
  valueCloseValue.close()
  valueCloseEngine.close()
}

function jsonConversionRejectsReentrantClose() {
  const engineClose = addon.Engine.create()
  const engineCloseValue = engineClose.evaluateValue('({ toJSON() { closeFromToJson(); return { ok: true } } })')
  engineClose.bind('closeFromToJson', () => engineClose.close())
  assert.throws(() => engineCloseValue.toJson(), statusIs(4), 'toJson rejects an Engine closed by guest conversion')
  engineCloseValue.close()
  engineClose.close()

  const valueCloseEngine = addon.Engine.create()
  const valueCloseValue = valueCloseEngine.evaluateValue('({ toJSON() { closeValueFromToJson(); return { ok: true } } })')
  valueCloseEngine.bind('closeValueFromToJson', () => valueCloseValue.close())
  assert.throws(() => valueCloseValue.toJson(), statusIs(5), 'toJson rejects a Value closed by guest conversion')
  assert.equal(valueCloseEngine.evaluate('40 + 2'), 42)
  valueCloseValue.close()
  valueCloseEngine.close()
}

function nodeValueFailuresRejectReentrantClose() {
  const cases = [
    ['toString', '({ toString() { closeNodeValue(); throw new Error("toString failed") } })', value => value.toString()],
    ['toJson', '({ toJSON() { closeNodeValue(); throw new Error("toJSON failed") } })', value => value.toJson()],
    ['get', '({ get x() { closeNodeValue(); throw new Error("getter failed") } })', value => value.get('x')],
    ['set', 'new Proxy({}, { set() { closeNodeValue(); throw new Error("setter failed") } })', value => value.set('x', 1)],
    ['has', 'new Proxy({}, { has() { closeNodeValue(); throw new Error("has failed") } })', value => value.has('x')],
    ['delete', 'new Proxy({}, { deleteProperty() { closeNodeValue(); throw new Error("delete failed") } })', value => value.delete('x')],
    ['keys', 'new Proxy({}, { ownKeys() { closeNodeValue(); throw new Error("ownKeys failed") } })', value => value.keys()],
    ['call', '(function() { closeNodeValue(); throw new Error("call failed") })', value => value.call(undefined)],
    ['construct', 'class ReentrantFailure { constructor() { closeNodeValue(); throw new Error("construct failed") } }', value => value.construct()],
    ['instanceOf', '({})', (value, engine) => {
      const constructor = engine.evaluateValue('({ [Symbol.hasInstance]() { closeNodeValue(); throw new Error("instanceOf failed") } })')
      try {
        return value.instanceOf(constructor)
      } finally {
        constructor.close()
      }
    }]
  ]

  for (const [method, source, invoke] of cases) {
    const instanceOfEngine = addon.Engine.create()
    let value
    try {
      value = instanceOfEngine.evaluateValue(source)
      instanceOfEngine.bind('closeNodeValue', () => value.close())
      assert.throws(() => invoke(value, instanceOfEngine), statusIs(5), `${method} reports a closed NodeValue after a throwing guest callback`)
      assert.equal(instanceOfEngine.evaluate('40 + 2'), 42, `${method} leaves the Engine usable`)
    } finally {
      if (value) value.close()
      instanceOfEngine.close()
    }
  }
}

stringConversionRejectsReentrantClose()
jsonConversionRejectsReentrantClose()
nodeValueFailuresRejectReentrantClose()

const first = addon.Engine.create()
const second = addon.Engine.create()
const handles = []
let closingEngine
try {
  const object = first.value({ count: 4, nested: ['first', null] })
  handles.push(object)
  assert.throws(() => first.evaluate.call(object, '1'), /status|engine|instance/i, 'Engine methods reject a NodeValue receiver without unwrapping it as Engine state')
  assert.equal(object.type(), 'object')
  assert.deepEqual(object.toHost(), { count: 4, nested: ['first', null] })
  assert.equal(object.toJson(), '{"count":4,"nested":["first",null]}')
  assert.equal(object.has('count'), true)
  assert.equal(object.has('missing'), false)

  const count = object.get('count')
  handles.push(count)
  assert.equal(count.type(), 'number')
  assert.equal(count.toNumber(), 4)
  object.set('count', 9)
  const updatedCount = object.get('count')
  handles.push(updatedCount)
  assert.equal(updatedCount.toNumber(), 9)

  const nested = object.get('nested')
  handles.push(nested)
  assert.equal(nested.type(), 'array')
  nested.set('0', 'changed')
  assert.deepEqual(nested.keys().toHost(), ['0', '1'])
  assert.deepEqual(nested.toHost(), ['changed', null])
  assert.equal(nested.delete('0'), true)

  const retained = count.retain()
  handles.push(retained)
  count.close()
  count.close()
  assert.throws(() => count.type(), statusIs(5))
  assert.equal(retained.toNumber(), 4)

  const truth = first.value(true)
  const text = first.value('hello')
  handles.push(truth, text)
  assert.equal(truth.toBool(), true)
  assert.equal(text.toString(), 'hello')

  const bytes = first.value(Uint8Array.from([3, 5, 8]))
  handles.push(bytes)
  assert.deepEqual([...new Uint8Array(bytes.copyBuffer())], [3, 5, 8])
  assert.deepEqual([...new Uint8Array(bytes.toHost())], [3, 5, 8])

  const global = first.global()
  handles.push(global)
  const math = global.get('Math')
  const max = math.get('max')
  const undefinedValue = first.value(undefined)
  const nullValue = first.value(null)
  handles.push(math, max, undefinedValue, nullValue)
  assert.equal(undefinedValue.toHost(), undefined)
  assert.equal(nullValue.toHost(), null)
  const receiver = undefinedValue
  assert.equal(max.type(), 'function')
  assert.equal(max.call(receiver, 2, 7, 5).toHost(), 7)
  assert.equal(max.call(undefined, 2, 7).toHost(), 7)

  const add = first.evaluateValue('(left, right) => left + right', 'function.js')
  handles.push(add)
  assert.equal(add.type(), 'function')
  assert.equal(add.call(receiver, 19, 23).toNumber(), 42)

  closingEngine = addon.Engine.create()
  closingEngine.bind('closeDuringEvaluation', () => {
    closingEngine.close()
    return { invalidated: true }
  })
  assert.throws(() => closingEngine.evaluateValue('closeDuringEvaluation()'), statusIs(4), 'evaluation cannot return a handle after a reentrant close')
  closingEngine.close()

  const arrayConstructor = global.get('Array')
  const constructed = arrayConstructor.construct('a', 'b')
  handles.push(arrayConstructor, constructed)
  assert.deepEqual(constructed.toHost(), ['a', 'b'])
  assert.equal(constructed.instanceOf(arrayConstructor), true)

  const promiseConstructor = global.get('Promise')
  const resolve = promiseConstructor.get('resolve')
  const promise = resolve.call(promiseConstructor, 12)
  handles.push(promiseConstructor, resolve, promise)
  assert.equal(promise.type(), 'object')
  assert.throws(() => promise.toHost())

  const oversizedText = first.evaluateValue("'x'.repeat(17 * 1024 * 1024)")
  handles.push(oversizedText)
  assert.throws(() => oversizedText.toHost(), /convert|budget|large|memory/i, 'toHost reports conversion budget failures')

  const throwingProxy = first.evaluateValue("new Proxy({}, { ownKeys() { throw new Error('ownKeys conversion failure') } })")
  handles.push(throwingProxy)
  assert.throws(() => throwingProxy.toHost(), /ownKeys conversion failure/, 'toHost propagates guest conversion exceptions')

  const foreign = second.value(1)
  handles.push(foreign)
  assert.throws(() => object.set('foreign', foreign), /different Engine/)
  assert.throws(() => first.value(foreign), /different Engine/)

  const closedByEngine = first.value({ alive: true })
  handles.push(closedByEngine)
  first.close()
  assert.throws(() => closedByEngine.type(), error => error && [5, 4].includes(error.status))
  closedByEngine.close()
} finally {
  for (const handle of handles)
    handle.close()
  first.close()
  second.close()
  if (closingEngine) closingEngine.close()
}
