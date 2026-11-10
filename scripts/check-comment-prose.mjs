#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { relative } from 'node:path';

const sourceExtensions = new Set([
  '.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.m', '.mm', '.zig', '.js', '.cjs', '.mjs', '.ts', '.tsx', '.sh', '.bash', '.zsh', '.py', '.rb', '.go', '.java', '.kt', '.kts', '.swift', '.ets',
]);
const excludedDirectories = new Set(['.git', '.zig-cache', 'zig-out', 'node_modules', 'vendor']);

function usage() {
  process.stderr.write('usage: node scripts/check-comment-prose.mjs --base <commit>\n');
}

function git(args) {
  return execFileSync('git', args, { encoding: 'buffer', stdio: ['ignore', 'pipe', 'pipe'] });
}

function parseBase(argv) {
  if (argv.length !== 2 || argv[0] !== '--base' || argv[1].startsWith('-')) {
    usage();
    process.exit(2);
  }
  return argv[1];
}

function verifyBase(base) {
  try {
    git(['rev-parse', '--verify', '--quiet', `${base}^{commit}`]);
  } catch {
    process.stderr.write(`comment prose check: base revision does not exist: ${base}\n`);
    process.exit(2);
  }
}

function nulPaths(bytes) {
  return Buffer.from(bytes).toString('utf8').split('\0').filter(Boolean);
}

function changedPaths(base) {
  const tracked = nulPaths(git(['diff', '--name-only', '-z', '--diff-filter=ACMR', base, '--']));
  const untracked = nulPaths(git(['ls-files', '--others', '--exclude-standard', '-z']));
  return new Map([...tracked.map(path => [path, false]), ...untracked.map(path => [path, true])]);
}

function isFirstPartySource(file) {
  const parts = file.split(/[\\/]/);
  if (parts.some(part => excludedDirectories.has(part))) return false;
  const last = parts.at(-1) ?? '';
  const extension = last.includes('.') ? `.${last.split('.').at(-1)}` : '';
  return sourceExtensions.has(extension) || last === 'Dockerfile' || last === 'Makefile';
}

function generated(contents) {
  return contents.split(/\r?\n/, 20).some(line => /^\s*(?:(?:\/\/|#|\/\*|\*)\s*)?(?:@generated\b|generated\s+(?:by|from)\b|do not edit\b)/i.test(line));
}

function changedLines(base, file) {
  const diff = Buffer.from(git(['diff', '--no-color', '--no-ext-diff', '--unified=0', base, '--', file])).toString('utf8');
  const lines = new Set();
  for (const line of diff.split('\n')) {
    const match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/);
    if (!match) continue;
    const start = Number(match[1]);
    const count = match[2] === undefined ? 1 : Number(match[2]);
    for (let number = start; number < start + count; number += 1) lines.add(number);
  }
  return lines;
}

function hashCommentsAllowed(file) {
  return /(?:\.(?:sh|bash|zsh)|(?:^|\/)(?:Dockerfile|Makefile))$/.test(file);
}

function commentRecords(file, contents) {
  const records = [];
  for (const [index, line] of contents.split(/\r?\n/).entries()) {
    const number = index + 1;
    const lineComment = line.match(hashCommentsAllowed(file) ? /^\s*(\/\/\/?|#)\s?(.*)$/ : /^\s*(\/\/\/?)\s?(.*)$/);
    if (lineComment) {
      records.push({ number, body: lineComment[2], kind: 'line' });
    }
  }
  return records;
}

function isStructured(body) {
  const text = body.trim();
  if (text === '') return true;
  if (/^(?:[-*+]\s+|\d+[.)]\s+)/.test(text)) return true;
  if (/^(?:usage|examples?|options?|arguments?):/i.test(text)) return true;
  if (/^(?:[$>]|if\b|then\b|else\b|elif\b|fi\b|for\b|while\b|do\b|done\b|case\b|esac\b)/.test(text)) return true;
  if (/^(?:!|@|#\s*(?:pragma|include|define|if|endif|error|warning)\b)/.test(text)) return true;
  if (/\b(?:SPDX-License-Identifier|copyright|license|permission is hereby|redistribution)\b/i.test(text)) return true;
  if (/\b(?:NOLINT|clang-format|shellcheck|cspell|prettier-ignore|eslint-)\b/i.test(text)) return true;
  if (/[{};]|=>/.test(text)) return true;
  if (/^(?:return|const|let|var|class|struct|function)\b.*(?:[({=]|=>)/.test(text)) return true;
  return false;
}

function findingsFor(file, contents, changed) {
  if (generated(contents)) return [];
  const findings = [];
  let paragraph = [];
  const flush = () => {
    if (paragraph.length < 2 || paragraph.some(record => isStructured(record.body))) {
      paragraph = [];
      return;
    }
    if (paragraph.some(record => changed.has(record.number))) {
      const firstChanged = paragraph.find(record => changed.has(record.number));
      findings.push({ file, line: firstChanged.number });
    }
    paragraph = [];
  };
  let previous = null;
  for (const record of commentRecords(file, contents)) {
    if (record.body.trim() === '' || (previous !== null && record.number !== previous + 1)) flush();
    if (record.body.trim() !== '') paragraph.push(record);
    previous = record.number;
  }
  flush();
  return findings;
}

function main() {
  const base = parseBase(process.argv.slice(2));
  verifyBase(base);
  const findings = [];
  for (const [file, untracked] of changedPaths(base)) {
    if (!isFirstPartySource(file) || !existsSync(file)) continue;
    const contents = readFileSync(file, 'utf8');
    if (contents.includes('\0')) continue;
    const changed = untracked ? new Set(contents.split(/\r?\n/).map((_, index) => index + 1)) : changedLines(base, file);
    findings.push(...findingsFor(relative('.', file) || file, contents, changed));
  }
  for (const finding of findings) process.stderr.write(`${finding.file}:${finding.line}: comment prose paragraphs must use one physical line\n`);
  process.exitCode = findings.length === 0 ? 0 : 1;
}

main();
