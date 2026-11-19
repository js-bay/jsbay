import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function validHarmonyVersion(version) {
  const number = '(?:0|[1-9][0-9]*)';
  const identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)';
  if (typeof version !== 'string' || !new RegExp(`^${number}\\.${number}\\.${number}(?:-${identifier}(?:\\.${identifier})*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$`).test(version)) return false;
  return Buffer.byteLength(`jsbay-${version}-harmony-quickjs_ng-arm64-v8a.har`) <= 255 && version.split(/[.+-]/, 3).every((part) => BigInt(part) <= 2147483647n);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url) && !validHarmonyVersion(process.argv[2])) {
  console.error('A valid Harmony package version is required');
  process.exitCode = 1;
}
