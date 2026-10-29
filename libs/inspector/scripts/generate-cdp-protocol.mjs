#!/usr/bin/env node
// Generate the exact protocol advertised by the inspector. The support manifest is deliberately narrower than CDP: advertising a command means this build has a non-noop handler for it.

import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = resolve(packageRoot, 'src/protocol-support.json');
const outputDir = resolve(packageRoot, 'src');
const args = process.argv.slice(2);
const check = args.includes('--check');
const fetchSource = args.includes('--fetch');
const sourceRootIndex = args.indexOf('--source-root');
const sourceRoot = sourceRootIndex === -1 ? null : resolve(args[sourceRootIndex + 1] ?? '');

if (args.includes('--help') || (sourceRootIndex !== -1 && !args[sourceRootIndex + 1])) {
  console.log('usage: node scripts/generate-cdp-protocol.mjs --source-root <dir> [--check]');
  console.log('       node scripts/generate-cdp-protocol.mjs --fetch [--check]');
  process.exit(sourceRootIndex !== -1 && !args[sourceRootIndex + 1] ? 2 : 0);
}
if (!sourceRoot && !fetchSource) {
  console.error('an offline --source-root containing js_protocol.json and browser_protocol.json is required; use --fetch only to refresh the fixed source');
  process.exit(2);
}

const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const fixed = manifest.source;

async function sourceText(name) {
  if (sourceRoot) return readFile(resolve(sourceRoot, name), 'utf8');
  const url = `https://raw.githubusercontent.com/${fixed.repository}/${fixed.commit}/json/${name}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.text();
}

const inputs = {};
for (const name of Object.keys(fixed.files)) {
  const text = await sourceText(name);
  const digest = createHash('sha256').update(text).digest('hex');
  if (digest !== fixed.files[name]) throw new Error(`${name} SHA-256 mismatch: got ${digest}`);
  inputs[name] = JSON.parse(text);
}

const sourceDomains = new Map();
for (const input of Object.values(inputs)) {
  for (const domain of input.domains ?? []) {
    if (sourceDomains.has(domain.domain)) throw new Error(`duplicate CDP domain ${domain.domain}`);
    sourceDomains.set(domain.domain, domain);
  }
}

function clone(value) { return structuredClone(value); }

function stripUnavailableRefs(value, allowedDomains) {
  if (Array.isArray(value)) return value.map((item) => stripUnavailableRefs(item, allowedDomains)).filter((item) => item !== null);
  if (value === null || typeof value !== 'object') return value;
  if (typeof value.$ref === 'string' && value.$ref.includes('.') && !allowedDomains.has(value.$ref.split('.', 1)[0])) return null;
  const out = {};
  for (const [key, item] of Object.entries(value)) {
    const cleaned = stripUnavailableRefs(item, allowedDomains);
    if (cleaned !== null) out[key] = cleaned;
  }
  return out;
}

function protocolFor(variantName, selected) {
  const allowedDomains = new Set(Object.keys(selected));
  const domains = [];
  for (const [name, support] of Object.entries(selected)) {
    const source = sourceDomains.get(name);
    if (!source) throw new Error(`${variantName}: unknown domain ${name}`);
    const wantedCommands = new Set(support.commands ?? []);
    const wantedEvents = new Set(support.events ?? []);
    const commands = (source.commands ?? []).filter((entry) => wantedCommands.delete(entry.name) === true);
    const events = (source.events ?? []).filter((entry) => wantedEvents.delete(entry.name) === true);
    if (wantedCommands.size || wantedEvents.size) throw new Error(`${variantName}: unsupported schema member ${[...wantedCommands, ...wantedEvents].join(', ')}`);
    const domain = clone(source);
    domain.commands = commands;
    domain.events = events;
    domains.push(stripUnavailableRefs(domain, allowedDomains));
  }
  const protocol = { version: { major: '1', minor: '3' }, domains };
  validateRefs(variantName, protocol);
  return `${JSON.stringify(protocol, null, 2)}\n`;
}

function validateRefs(variantName, protocol) {
  const types = new Set();
  for (const domain of protocol.domains) {
    for (const type of domain.types ?? []) types.add(`${domain.domain}.${type.id}`);
  }
  function visit(value, domainName) {
    if (Array.isArray(value)) return value.forEach((item) => visit(item, domainName));
    if (value === null || typeof value !== 'object') return;
    if (typeof value.$ref === 'string') {
      const qualified = value.$ref.includes('.') ? value.$ref : `${domainName}.${value.$ref}`;
      if (!types.has(qualified)) throw new Error(`${variantName}: unresolved CDP reference ${qualified}`);
    }
    for (const item of Object.values(value)) visit(item, domainName);
  }
  for (const domain of protocol.domains) visit(domain, domain.domain);
}

const variants = new Map(Object.entries(manifest.variants));
for (const baseName of manifest.withoutHeapSnapshot ?? []) {
  const base = manifest.variants[baseName];
  if (!base) throw new Error(`withoutHeapSnapshot references unknown variant ${baseName}`);
  const selected = clone(base);
  delete selected.HeapProfiler;
  variants.set(`${baseName}_no_heap`, selected);
}

let failed = false;
for (const [variantName, selected] of variants) {
  const generated = protocolFor(variantName, selected);
  const outPath = resolve(outputDir, `protocol-${variantName.replaceAll('_', '-')}.json`);
  if (check) {
    const existing = await readFile(outPath, 'utf8').catch(() => null);
    if (existing !== generated) {
      console.error(`${outPath} is stale; run this command without --check`);
      failed = true;
    }
  } else {
    await writeFile(outPath, generated);
    console.log(`wrote ${outPath}`);
  }
}
process.exitCode = failed ? 1 : 0;
