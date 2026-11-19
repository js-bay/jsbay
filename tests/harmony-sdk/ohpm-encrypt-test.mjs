import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = mkdtempSync(join(tmpdir(), 'jsbay-ohpm-crypto-test-'));
try {
  const fake = join(root, 'crypto.cjs');
  writeFileSync(fake, `exports.createCrypto = async () => {}; exports.loadCustomCrypto = () => ({ encrypt: (value) => value === 'example-secret' ? 'security:01:abc:123' : '', decrypt: () => 'example-secret', destroy: () => {} });\n`);
  const script = resolve('scripts/ohpm-encrypt-passphrase.mjs');
  const run = (secret) => spawnSync(process.execPath, [script, fake, join(root, 'crypto')], { input: secret, encoding: 'utf8' });
  const valid = run('example-secret\n');
  assert.equal(valid.status, 0, valid.stderr);
  assert.equal(valid.stdout.trim(), 'security:01:abc:123');
  assert.ok(!valid.stdout.includes('example-secret') && !valid.stderr.includes('example-secret'));
  const invalid = run('different-secret');
  assert.notEqual(invalid.status, 0);
  assert.ok(!invalid.stderr.includes('different-secret'));
} finally {
  rmSync(root, { recursive: true, force: true });
}
