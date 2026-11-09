import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const sourcePath = resolve(here, '../src/backend/hermes/hermes_inspector.cpp');

function sourceFunction(source) {
  const marker = 'extern "C" void hermes_inspector_console(';
  const first = source.indexOf(marker);
  assert.notEqual(first, -1, 'hermes_inspector_console was not found');
  assert.equal(source.indexOf(marker, first + marker.length), -1, 'hermes_inspector_console was found more than once');
  const open = source.indexOf('{', first);
  assert.notEqual(open, -1, 'hermes_inspector_console has no body');
  let depth = 0;
  let quote = null;
  let lineComment = false;
  let blockComment = false;
  for (let index = open; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (character === '*' && next === '/') {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (character === '\\') {
        index += 1;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === '/' && next === '/') {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === '/' && next === '*') {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === '{') depth += 1;
    if (character === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(first, index + 1);
    }
  }
  throw new Error('hermes_inspector_console body is not balanced');
}

function contractTranslationUnit(functionBody) {
  return `#include <chrono>
#include <cstddef>
#include <utility>
#include <vector>

namespace jsi {
class Runtime {};
class Value {
 public:
  int marker = 0;
  Value() = default;
  Value(Runtime &, const Value &other) : marker(other.marker) {}
};
}

using HermesValue = void *;

namespace cdp {
enum class ConsoleAPIType { kLog, kInfo, kWarning, kError };
struct ConsoleMessage {
  double timestamp;
  ConsoleAPIType type;
  std::vector<jsi::Value> values;
};
}

struct DebugApi {
  std::vector<cdp::ConsoleMessage> messages;
  void addConsoleMessage(cdp::ConsoleMessage message) { messages.push_back(std::move(message)); }
};

struct JsbayHermesInspector {
  jsi::Runtime *runtime;
  DebugApi *debug_api;
};

struct JsbayHermesContext {
  JsbayHermesInspector *inspector;
};

static JsbayHermesInspector *hermes_context_get_inspector(JsbayHermesContext *context) {
  return context ? context->inspector : nullptr;
}

${functionBody}

int main() {
  jsi::Runtime runtime;
  DebugApi debugApi;
  JsbayHermesInspector inspector{&runtime, &debugApi};
  JsbayHermesContext context{&inspector};

  hermes_inspector_console(&context, nullptr, 0, 0);
  if (debugApi.messages.size() != 1 || debugApi.messages[0].type != cdp::ConsoleAPIType::kLog || !debugApi.messages[0].values.empty()) return 10;
  hermes_inspector_console(&context, nullptr, 0, 2);
  if (debugApi.messages.size() != 2 || debugApi.messages[1].type != cdp::ConsoleAPIType::kWarning || !debugApi.messages[1].values.empty()) return 11;

  jsi::Value value;
  value.marker = 17;
  HermesValue values[] = {static_cast<void *>(&value)};
  hermes_inspector_console(&context, values, 1, 3);
  if (debugApi.messages.size() != 3 || debugApi.messages[2].type != cdp::ConsoleAPIType::kError || debugApi.messages[2].values.size() != 1 || debugApi.messages[2].values[0].marker != 17) return 12;

  const auto accepted = debugApi.messages.size();
  hermes_inspector_console(nullptr, values, 1, 0);
  hermes_inspector_console(&context, nullptr, 1, 0);
  if (debugApi.messages.size() != accepted) return 13;
  return 0;
}
`;
}

test('Hermes console bridge accepts empty arguments and preserves level', () => {
  const functionBody = sourceFunction(readFileSync(sourcePath, 'utf8'));
  const directory = mkdtempSync(join(tmpdir(), 'jsbay-hermes-console-'));
  const input = join(directory, 'console-contract.cpp');
  const output = join(directory, 'console-contract');
  try {
    writeFileSync(input, contractTranslationUnit(functionBody));
    const compiler = process.env.CXX || 'c++';
    const compiled = spawnSync(compiler, ['-std=c++17', input, '-o', output], { encoding: 'utf8', timeout: 30000 });
    assert.equal(compiled.error, undefined, `C++ compiler did not start: ${compiled.error}`);
    assert.equal(compiled.status, 0, `${basename(input)} compilation failed:\n${compiled.stdout}\n${compiled.stderr}`);
    const ran = spawnSync(output, [], { encoding: 'utf8', timeout: 10000 });
    assert.equal(ran.error, undefined, `contract executable did not start: ${ran.error}`);
    assert.equal(ran.status, 0, `contract executable failed with ${ran.status}:\n${ran.stdout}\n${ran.stderr}`);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
