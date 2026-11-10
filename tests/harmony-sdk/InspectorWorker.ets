import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Engine } from '@js-bay/harmony';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
let engine: Engine | undefined = undefined;

workerPort.onmessage = (message: MessageEvents): void => {
  if (message.data === 'start' && engine === undefined) {
    engine = Engine.create(7133);
    const port = engine.inspectorStart(0);
    if (port === 0) {
      engine.close();
      throw new Error('Inspector did not start');
    }
    hilog.info(0x5A4A, 'JsBayCDP', 'READY %{public}d', port);
    workerPort.postMessage({ port: port });
    return;
  }
  if (message.data !== 'close') {
    return;
  }
  if (engine !== undefined) {
    engine.inspectorStop();
    engine.close();
    engine = undefined;
  }
  workerPort.postMessage({ closed: true });
};
