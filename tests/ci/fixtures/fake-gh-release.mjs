#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
const state = JSON.parse(readFileSync(process.env.FAKE_GH_STATE, 'utf8'));
const save = () => writeFileSync(process.env.FAKE_GH_STATE, JSON.stringify(state));
const value = name => args.find(arg => arg.startsWith(`${name}=`))?.slice(name.length + 1);
let result;
if (args.some(a => a.endsWith('/assets?per_page=100'))) result = [state.release?.assets ?? []];
else if (args.some(a => a.includes('/releases?per_page=100'))) result = [state.release ? [state.release] : []];
else if (args.includes('https://uploads.example.test/assets?name=' + encodeURIComponent(args.at(-1).split('/').at(-1)))) {
  const path = args.at(-1), name = path.split('/').at(-1);
  const digest = `sha256:${createHash('sha256').update(readFileSync(path)).digest('hex')}`;
  result = { name, digest }; state.release.assets.push(result); save();
} else if (args.includes('POST')) {
  result = state.release = { id: 1, tag_name: value('tag_name'), target_commitish: value('target_commitish'), draft: true, upload_url: 'https://uploads.example.test/assets{?name,label}', assets: [] }; save();
} else if (args.includes('PATCH')) { state.release.draft = false; result = state.release; save(); }
else throw new Error(`unexpected gh arguments: ${args.join(' ')}`);
process.stdout.write(JSON.stringify(result));
