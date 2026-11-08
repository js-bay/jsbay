import { Engine, type JsBayError, type AsyncHostCallback, type HostValue } from '../../sdk/node'

const engine = Engine.create()
const value: HostValue = engine.evaluate('1', 'types.js')
const eventual: Promise<HostValue> = engine.evaluateAsync('Promise.resolve(1)')
const callback: AsyncHostCallback = async value => value
engine.bindAsync('echo', callback)
engine.bind('log', value => { console.log(value) })
engine.bindAsync('done', async () => { await Promise.resolve() })
const error: JsBayError = new Error('native failure')
void [value, error, eventual]
// @ts-expect-error Engines are created by the factory.
new Engine()
// @ts-expect-error JsBayError is a type, not an exported constructor.
new JsBayError()
engine.close()
