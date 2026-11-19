import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const [modulePath, cryptoPath] = process.argv.slice(2);
try {
  if (!modulePath || !cryptoPath) throw new Error('Missing configuration');
  const passphrase = readFileSync(0, 'utf8').replace(/\r?\n$/, '');
  if (!passphrase) throw new Error('Missing passphrase');
  const implementation = createRequire(import.meta.url)(resolve(modulePath));
  await implementation.createCrypto(cryptoPath);
  const crypto = implementation.loadCustomCrypto(cryptoPath);
  if (!crypto) throw new Error('Invalid crypto component');
  try {
    const encrypted = crypto.encrypt(passphrase);
    if (typeof encrypted !== 'string' || !encrypted.startsWith('security:') || crypto.decrypt(encrypted) !== passphrase) {
      throw new Error('Invalid ciphertext');
    }
    process.stdout.write(`${encrypted}\n`);
  } finally {
    crypto.destroy();
  }
} catch {
  console.error('OHPM password encryption failed');
  process.exitCode = 1;
}
