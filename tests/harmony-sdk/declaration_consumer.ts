import { Engine, JsBayStatus, JsBayStatusError, JsException, Value } from '../../sdk/harmony';

declare const value: Value;
const jsError: JsException = new JsException(value);
const statusError: JsBayStatusError = new JsBayStatusError(JsBayStatus.InvalidArgument);
const codedError: JsBayStatusError = new JsBayStatusError(JsBayStatus.StaleValue, 'JSBAY_STALE_VALUE');
void [jsError, statusError, codedError];

// @ts-expect-error Engine instances are created with Engine.create.
new Engine();
// @ts-expect-error Values are returned by an Engine or a callback.
new Value();
// @ts-expect-error JavaScript exceptions require an owned Value.
new JsException('message');
