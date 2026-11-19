import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [rootArg, backend, version] = process.argv.slice(2);
const packageNames = { quickjs: '@jsbay/quickjs', quickjs_ng: '@jsbay/quickjs_ng' };
if (!rootArg || !Object.hasOwn(packageNames, backend) || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/.test(version ?? '')) {
  throw new Error('Usage: prepare-harmony-ohpm.mjs <repository> <quickjs|quickjs_ng> <version>');
}

const root = resolve(rootArg);
const sdk = join(root, 'sdk/harmony');
const manifestPath = join(sdk, 'oh-package.json5');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const name = packageNames[backend];
manifest.name = name;
manifest.version = version;
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

const profilePath = join(root, 'tests/harmony-sdk/fixture/build-profile.json5');
const profile = JSON.parse(readFileSync(profilePath, 'utf8'));
const debug = profile.app.buildModeSet.find((mode) => mode.name === 'debug');
if (!debug) throw new Error('Harmony build profile is missing its debug build mode');
profile.app.buildModeSet = profile.app.buildModeSet.filter((mode) => mode.name !== 'release');
profile.app.buildModeSet.push({ ...structuredClone(debug), name: 'release' });
writeFileSync(profilePath, `${JSON.stringify(profile, null, 2)}\n`);

copyFileSync(join(root, 'LICENSE'), join(sdk, 'LICENSE'));
writeFileSync(join(sdk, 'CHANGELOG.md'), `# Changelog\n\n## ${version}\n\nInitial ${backend} release candidate.\n`);
writeFileSync(join(sdk, 'README.md'), `# ${name}\n\nJsBay's ArkTS SDK with the ${backend} JavaScript engine. Create and use an engine on its own ArkTS Worker, and close owned values before closing the engine.\n\n\`\`\`sh\nohpm install ${name}@${version}\n\`\`\`\n\n\`\`\`ts\nimport { Engine } from '${name}';\n\nconst engine = Engine.create(1);\ntry {\n  const result = engine.evaluate('1 + 1', 'example.js');\n  try {\n    const text = result.toUtf8();\n  } finally {\n    result.close();\n  }\n} finally {\n  engine.close();\n}\n\`\`\`\n\nUse this example from a dedicated ArkTS Worker. Configure normalized OHM URLs when consuming the bytecode HAR.\n`);
