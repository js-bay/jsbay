import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { validHarmonyVersion } from './validate-harmony-version.mjs';

const [rootArg, backend, version] = process.argv.slice(2);
const packageNames = { quickjs: '@jsbay/quickjs', quickjs_ng: '@jsbay/quickjs_ng' };
if (!rootArg || !Object.hasOwn(packageNames, backend) || !validHarmonyVersion(version)) {
  throw new Error('Usage: prepare-harmony-ohpm.mjs <repository> <quickjs|quickjs_ng> <version>');
}

const root = resolve(rootArg);
const sdk = join(root, 'sdk/harmony');
const manifestPath = join(sdk, 'oh-package.json5');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const name = packageNames[backend];
manifest.name = name;
manifest.version = version;
manifest.author = { name: 'jsbay', url: 'https://github.com/js-bay/jsbay' };
manifest.repository = 'https://github.com/js-bay/jsbay';
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

const profilePath = join(root, 'tests/harmony-sdk/fixture/build-profile.json5');
const profile = JSON.parse(readFileSync(profilePath, 'utf8'));
const debug = profile.app.buildModeSet.find((mode) => mode.name === 'debug');
if (!debug) throw new Error('Harmony build profile is missing its debug build mode');
profile.app.buildModeSet = profile.app.buildModeSet.filter((mode) => mode.name !== 'release');
profile.app.buildModeSet.push({ ...structuredClone(debug), name: 'release' });
writeFileSync(profilePath, `${JSON.stringify(profile, null, 2)}\n`);

copyFileSync(join(root, 'LICENSE'), join(sdk, 'LICENSE'));
writeFileSync(join(sdk, 'CHANGELOG.md'), `# Changelog\n\n## ${version}\n\nRelease the ${backend} engine package.\n`);
writeFileSync(join(sdk, 'README.md'), `# ${name}

JsBay runs JavaScript in a dedicated ArkTS Worker using the ${backend} engine. This HAR contains the arm64-v8a native library.

## Install

In the consuming module directory, install the package:

\`\`\`sh
ohpm install ${name}@${version}
\`\`\`

Choose one JsBay engine package per app. The packages expose the same API and contain a native library with the same name.

## Configure the app

In the app-level \`build-profile.json5\`, set the product's \`runtimeOS\` and enable normalized OHM URLs for every build mode that consumes this bytecode HAR:

\`\`\`json5
{
  "app": {
    "products": [{ "name": "default", "runtimeOS": "HarmonyOS" }],
    "buildModeSet": [{
      "name": "debug",
      "buildOption": { "strictMode": { "useNormalizedOHMUrl": true } }
    }]
  }
}
\`\`\`

Merge these settings into the existing product and build modes; keep the app's other settings. Apply the same option to release builds.

## Run JavaScript

Create \`entry/src/main/ets/workers/JsBayWorker.ets\`:

\`\`\`ts
import { MessageEvents, ThreadWorkerGlobalScope, worker } from '@kit.ArkTS';
import { Engine } from '${name}';

const port: ThreadWorkerGlobalScope = worker.workerPort;
port.onmessage = (message: MessageEvents): void => {
  if (message.data !== 'start') return;
  const engine = Engine.create(1);
  try {
    const result = engine.evaluate('40 + 2', 'example.js');
    try {
      port.postMessage(result.toNumber());
    } finally {
      result.close();
    }
  } finally {
    engine.close();
  }
};
\`\`\`

Start the Worker from the entry module and receive the result:

\`\`\`ts
import { MessageEvents, worker } from '@kit.ArkTS';

const jsWorker = new worker.ThreadWorker('entry/ets/workers/JsBayWorker.ets');
jsWorker.onmessage = (message: MessageEvents): void => {
  console.info(\`Result: \${message.data}\`);
  jsWorker.terminate();
};
jsWorker.postMessage('start');
\`\`\`

Keep each engine and its values on the Worker that created them. Close owned values before closing the engine. A Worker does not isolate native crashes from the host process.
`);
