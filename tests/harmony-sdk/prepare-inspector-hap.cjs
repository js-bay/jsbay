#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const outputArg = process.argv[2];
if (!outputArg) throw new Error('Usage: prepare-inspector-hap.cjs <new-output-directory> [HAR]');
const output = path.resolve(outputArg);
const har = path.resolve(process.argv[3] || path.join(__dirname, '../../sdk/harmony/build/default/outputs/default/jsbay_harmony.har'));
if (!fs.statSync(har).isFile()) throw new Error('HAR must be a regular file');
// A fresh destination prevents overwriting local signing configuration or another fixture.
fs.mkdirSync(output);
const template = path.join(__dirname, 'hap-crash-isolation');
const files = [
  'AppScope/resources', 'entry/src/main/resources',
  'entry/src/main/ets/entryability/EntryAbility.ets',
  'build-profile.json5', 'entry/build-profile.json5',
  'hvigorfile.ts', 'entry/hvigorfile.ts', 'hvigor/hvigor-config.json5',
];
for (const file of files) {
  const target = path.join(output, file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.cpSync(path.join(template, file), target, { recursive: true });
}
function writeJson(file, value) {
  const target = path.join(output, file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, JSON.stringify(value, null, 2) + '\n');
}
const app = JSON.parse(fs.readFileSync(path.join(template, 'AppScope/app.json5'), 'utf8'));
app.app.bundleName = 'com.example.jsbay.inspector';
app.app.versionName = '1.0.0';
writeJson('AppScope/app.json5', app);
writeJson('AppScope/resources/base/element/string.json', { string: [{ name: 'app_name', value: 'JsBay Inspector' }] });
writeJson('entry/src/main/resources/base/element/string.json', { string: [
  { name: 'module_desc', value: 'JsBay CDP SDK consumer' },
  { name: 'EntryAbility_desc', value: 'Inspector owner Worker host' },
] });
const moduleConfig = JSON.parse(fs.readFileSync(path.join(template, 'entry/src/main/module.json5'), 'utf8'));
moduleConfig.module.abilities = moduleConfig.module.abilities.filter(ability => ability.name === 'EntryAbility');
moduleConfig.module.requestPermissions = [{ name: 'ohos.permission.INTERNET' }];
writeJson('entry/src/main/module.json5', moduleConfig);
writeJson('package.json', { name: 'jsbay-inspector', version: '1.0.0', private: true });
writeJson('oh-package.json5', { modelVersion: '5.0.0', name: 'jsbay-inspector', version: '1.0.0', dependencies: {} });
writeJson('entry/oh-package.json5', { modelVersion: '5.0.0', name: 'entry', version: '1.0.0', dependencies: { '@js-bay/harmony': `file:${har}` } });
for (const [source, target] of [
  ['InspectorIndex.ets', 'entry/src/main/ets/pages/Index.ets'],
  ['InspectorWorker.ets', 'entry/src/main/ets/workers/InspectorWorker.ets'],
]) {
  fs.mkdirSync(path.dirname(path.join(output, target)), { recursive: true });
  fs.copyFileSync(path.join(__dirname, source), path.join(output, target));
}
console.log('Inspector HAP prepared. Configure local signing, install dependencies in entry, and assembleHap with the Harmony SDK.');
