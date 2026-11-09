import { MessageEvents, worker } from '@kit.ArkTS';

interface InspectorReply {
  port?: number;
  closed?: boolean;
}

@Entry
@Component
struct Index {
  @State port: number = 0;
  private inspectorWorker: worker.ThreadWorker | undefined = undefined;

  aboutToAppear(): void {
    this.inspectorWorker = new worker.ThreadWorker('entry/ets/workers/InspectorWorker.ets');
    this.inspectorWorker.onmessage = (message: MessageEvents): void => {
      const reply = message.data as InspectorReply;
      if (reply.port !== undefined) {
        this.port = reply.port;
      }
      if (reply.closed === true) {
        this.inspectorWorker?.terminate();
        this.inspectorWorker = undefined;
        this.port = 0;
      }
    };
    this.inspectorWorker.postMessage('start');
  }

  private stopInspector(): void {
    this.inspectorWorker?.postMessage('close');
  }

  build() {
    Column() {
      Text(`CDP ${this.port}`)
      Button('Stop').onClick(() => this.stopInspector())
    }
  }
}
