import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const script = resolve(dirname(fileURLToPath(import.meta.url)), '../scripts/check-comment-prose.mjs');

function command(directory, args) {
  return execFileSync('git', args, { cwd: directory, encoding: 'utf8', stdio: 'pipe' });
}

function createRepository(files) {
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-comment-prose-'));
  command(directory, ['init', '--quiet']);
  command(directory, ['config', 'user.name', 'Test User']);
  command(directory, ['config', 'user.email', 'test@example.invalid']);
  for (const [file, contents] of Object.entries(files)) {
    mkdirSync(dirname(join(directory, file)), { recursive: true });
    writeFileSync(join(directory, file), contents);
  }
  command(directory, ['add', '.']);
  command(directory, ['commit', '--quiet', '-m', 'base']);
  return directory;
}

function write(directory, file, contents) {
  mkdirSync(dirname(join(directory, file)), { recursive: true });
  writeFileSync(join(directory, file), contents);
}

function check(directory, base = 'HEAD') {
  return spawnSync(process.execPath, [script, '--base', base], {
    cwd: directory,
    encoding: 'utf8',
  });
}

function withRepository(files, body) {
  const directory = createRepository(files);
  try {
    body(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test('rejects a changed C++ prose paragraph split across line comments', () => {
  withRepository({ 'src/demo.cpp': 'int main() { return 0; }\n' }, directory => {
    write(directory, 'src/demo.cpp', '// The connection must remain available while the debugger is paused.\n// The event loop resumes only after the owner acknowledges the command.\nint main() { return 0; }\n');
    const result = check(directory);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /src\/demo\.cpp:1:/);
  });
});

test('rejects teardown prose split across comment lines', () => {
  const paragraph = '// A disconnected client must not strand the engine in a debugger pause.\n// AsyncDebuggerAPI owns the pause loop, so this is safe from the reader thread.\n';
  withRepository({ 'src/demo.cpp': 'int main() { return 0; }\n' }, directory => {
    write(directory, 'src/demo.cpp', `${paragraph}int main() { return 0; }\n`);
    const result = check(directory);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /src\/demo\.cpp:\d+:/);
  });
});

test('does not treat a prose mention of function as a code example', () => {
  withRepository({ 'src/demo.cpp': 'int main() { return 0; }\n' }, directory => {
    write(directory, 'src/demo.cpp', '// The function must remain live while the debugger is paused.\n// The owner resumes it after the command completes.\nint main() { return 0; }\n');
    const result = check(directory);
    assert.equal(result.status, 1);
  });
});

test('does not treat an ordinary generated identifier as a generated-source marker', () => {
  withRepository({ 'src/demo.cpp': 'int main() { return 0; }\n' }, directory => {
    write(directory, 'src/demo.cpp', '// The generated identifier remains available after a reconnect.\n// The owner validates it before resuming execution.\nconst int generated = 1;\n');
    const result = check(directory);
    assert.equal(result.status, 1);
  });
});

test('accepts one physical line of prose', () => {
  withRepository({ 'scripts/demo.sh': '#!/usr/bin/env bash\n' }, directory => {
    write(directory, 'scripts/demo.sh', '#!/usr/bin/env bash\n# The owner resumes the worker after the debugger disconnects.\n');
    const result = check(directory);
    assert.equal(result.status, 0, result.stderr);
  });
});

test('preserves blank separators, lists, code examples, and usage directives', () => {
  withRepository({ 'scripts/demo.sh': '#!/usr/bin/env bash\n' }, directory => {
    write(directory, 'scripts/demo.sh', '#!/usr/bin/env bash\n# First independent sentence.\n#\n# Second independent sentence.\n# - first item\n# - second item\n# if enabled; then\n#   run_task\n# fi\n# Usage: demo <argument>\n# The caller owns the process lifecycle.\n');
    const result = check(directory);
    assert.equal(result.status, 0, result.stderr);
  });
});

test('does not report an untouched legacy paragraph', () => {
  withRepository({ 'src/demo.cpp': '// This legacy paragraph spans two lines.\n// It remains outside the changed diff.\nint main() { return 0; }\n' }, directory => {
    write(directory, 'src/demo.cpp', '// This legacy paragraph spans two lines.\n// It remains outside the changed diff.\nint main() { return 1; }\n');
    const result = check(directory);
    assert.equal(result.status, 0, result.stderr);
  });
});

test('fails when the requested base revision is absent', () => {
  withRepository({ 'src/demo.cpp': 'int main() { return 0; }\n' }, directory => {
    const result = check(directory, 'missing-base');
    assert.equal(result.status, 2);
    assert.match(result.stderr, /base revision/i);
  });
});

test('handles changed paths containing spaces', () => {
  withRepository({ 'src/with space.cpp': 'int main() { return 0; }\n' }, directory => {
    write(directory, 'src/with space.cpp', '// This prose paragraph is intentionally split across two physical lines.\n// The diagnostic must retain the path with its embedded space.\nint main() { return 0; }\n');
    const result = check(directory);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /src\/with space\.cpp:1:/);
  });
});

test('checks untracked first-party source files', () => {
  withRepository({ 'README.md': '# Demo\n' }, directory => {
    write(directory, 'src/untracked.cpp', '// An untracked source comment must not evade the policy.\n// This second line makes the same prose paragraph invalid.\n');
    const result = check(directory);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /src\/untracked\.cpp:1:/);
  });
});
