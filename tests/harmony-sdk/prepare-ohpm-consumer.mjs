import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [outputArg, harArg, backend, dependency] = process.argv.slice(2);
if (!outputArg || !harArg || !['quickjs', 'quickjs_ng'].includes(backend) || !dependency) {
  throw new Error('Usage: prepare-ohpm-consumer.mjs <output> <har> <backend> <dependency>');
}
const output = resolve(outputArg);
const name = `@jsbay/${backend}`;
execFileSync(process.execPath, ['tests/harmony-sdk/prepare-inspector-hap.cjs', output, resolve(harArg)], { stdio: 'inherit' });
const manifestPath = join(output, 'entry/oh-package.json5');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
manifest.dependencies = { [name]: dependency };
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
writeFileSync(join(output, 'entry/src/main/ets/workers/InspectorWorker.ets'), `import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Engine } from '${name}';

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;
workerPort.onmessage = (message: MessageEvents): void => {
  if (message.data !== 'start') return;
  const engine = Engine.create(7133);
  try {
    const result = engine.evaluate('40 + 2', 'consumer.js');
    try {
      if (result.toNumber() !== 42) throw new Error('Unexpected JavaScript result');
      hilog.info(0x5A4A, 'JsBayOHPM', 'PASS ${backend}');
      workerPort.postMessage({ port: 42 });
    } finally {
      result.close();
    }
  } finally {
    engine.close();
  }
};
`);
