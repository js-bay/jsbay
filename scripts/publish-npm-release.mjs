import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const [directory, version, sourceSha, operation] = process.argv.slice(2);
if (!directory || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version ?? '') || !/^[a-f0-9]{40}$/.test(sourceSha ?? '')
    || !['verify', 'publish'].includes(operation)) throw new Error('expected an npm artifact directory, release version, source SHA and verify or publish');
const read = name => readFile(join(directory, name), 'utf8');
if ((await read('COMMIT')).trim() !== sourceSha || (await read('VERSION')).trim() !== version) throw new Error('npm artifact does not match the original source SHA and release version');

const engines = ['jsc', 'quickjs', 'quickjsng'];
const main = engines.map(engine => `jsbay-${engine}-${version}.tgz`);
const platform = engines.flatMap(engine => (engine === 'jsc' ? ['macos'] : ['linux', 'macos']).flatMap(os =>
  ['arm64', 'x64'].map(arch => `jsbay-${engine}${os}${arch}-${version}.tgz`)));
for (const [type, archives] of [['main', main], ['platform', platform]]) {
  const actual = (await readdir(join(directory, type))).sort();
  if (actual.join('\n') !== [...archives].sort().join('\n')) throw new Error(`unexpected npm ${type} package set`);
}

const archives = [...platform.map(name => `platform/${name}`), ...main.map(name => `main/${name}`)];
const checksums = new Map();
for (const line of (await read('SHA512SUMS')).trimEnd().split('\n')) {
  const match = /^([a-f0-9]{128})  (\S+)$/.exec(line);
  if (!match || checksums.has(match[2])) throw new Error('invalid npm artifact SHA512SUMS');
  checksums.set(match[2], match[1]);
}
if (checksums.size !== archives.length) throw new Error('npm artifact SHA512SUMS does not contain the complete package set');
for (const archive of archives) {
  const hash = createHash('sha512');
  for await (const chunk of createReadStream(join(directory, archive))) hash.update(chunk);
  if (hash.digest('hex') !== checksums.get(archive)) throw new Error(`npm artifact checksum mismatch: ${archive}`);
}

if (operation === 'publish') {
  if (!process.env.NODE_AUTH_TOKEN) throw new Error('NPM_TOKEN is required in the release environment');
  const script = fileURLToPath(new URL('./publish-npm-package.mjs', import.meta.url));
  for (const archive of archives) {
    const integrity = Buffer.from(checksums.get(archive), 'hex').toString('base64');
    execFileSync(process.execPath, [script, join(directory, archive), `sha512-${integrity}`], { stdio: 'inherit' });
  }
}
