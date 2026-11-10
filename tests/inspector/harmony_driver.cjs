'use strict';

// Runs against an already installed Harmony inspector HAP. It validates that the page exposes the Worker-owned CDP port and that Stop closes that port.

const assert = require('node:assert/strict');
const { execFile, execFileSync, spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const HDC_TIMEOUT_MS = 20000;

function usage() {
  process.stderr.write('Usage: HDC=/path/to/hdc HDC_SERIAL=<target> node tests/inspector/harmony_driver.cjs --host 127.0.0.1 --port <forwarded-port> --device-port <port>\n');
}

function parseArgs(argv) {
  const options = { host: '127.0.0.1', port: 0, devicePort: 0 };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--host') options.host = argv[++index];
    else if (arg === '--port') options.port = Number(argv[++index]);
    else if (arg === '--device-port') options.devicePort = Number(argv[++index]);
    else if (arg === '--help' || arg === '-h') {
      usage();
      process.exit(0);
    } else {
      usage();
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  for (const [name, value] of [['--port', options.port], ['--device-port', options.devicePort]]) {
    if (!Number.isInteger(value) || value < 1 || value > 65535) throw new Error(`invalid ${name}`);
  }
  return options;
}

function hdc(args, options = {}) {
  return execFileSync(process.env.HDC, ['-t', process.env.HDC_SERIAL, ...args], {
    encoding: 'utf8',
    ...options,
    timeout: HDC_TIMEOUT_MS,
  });
}

function hdcAsync(args) {
  return new Promise((resolve, reject) => {
    execFile(process.env.HDC, ['-t', process.env.HDC_SERIAL, ...args], { encoding: 'utf8', timeout: HDC_TIMEOUT_MS }, (error, stdout, stderr) => {
      if (error) {
        error.stdout = stdout;
        error.stderr = stderr;
        reject(error);
      } else {
        resolve({ stdout, stderr });
      }
    });
  });
}

function getVersion(host, port) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host, port, path: '/json/version', method: 'GET', timeout: 5000 }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ statusCode: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      response.on('error', reject);
    });
    request.on('error', reject);
    request.on('timeout', () => {
      const error = new Error('HTTP timeout');
      error.code = 'ETIMEDOUT';
      request.destroy(error);
    });
    request.end();
  });
}

function textNodes(value, out = []) {
  if (Array.isArray(value)) {
    for (const entry of value) textNodes(entry, out);
  } else if (value && typeof value === 'object') {
    const attributes = value.attributes;
    if (attributes && typeof attributes === 'object') out.push(attributes);
    for (const entry of Object.values(value)) textNodes(entry, out);
  }
  return out;
}

function stopButton(layout) {
  const button = textNodes(layout).find(attributes => attributes.text === 'Stop' && attributes.clickable === 'true' && attributes.visible === 'true');
  assert.ok(button, 'visible clickable Stop button was not found in the Harmony UI layout');
  const match = /^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/.exec(button.bounds || '');
  assert.ok(match, `Stop button has invalid bounds: ${JSON.stringify(button.bounds)}`);
  return {
    x: Math.floor((Number(match[1]) + Number(match[3])) / 2),
    y: Math.floor((Number(match[2]) + Number(match[4])) / 2),
  };
}

async function dumpLayout(directory, label) {
  const remote = `/data/local/tmp/jsbay-harmony-layout-${process.pid}-${label}.json`;
  const local = path.join(directory, `${label}.json`);
  try {
    hdc(['shell', 'uitest', 'dumpLayout', '-p', remote]);
    await hdcAsync(['file', 'recv', remote, local]);
    return JSON.parse(fs.readFileSync(local, 'utf8'));
  } finally {
    try {
      hdc(['shell', 'rm', '-f', remote]);
    } catch (_) {
      // Preserve the original test failure; the payload is run-owned and remote cleanup is best effort.
    }
  }
}

async function runE2E(options) {
  const child = spawn(process.execPath, [path.join(__dirname, 'e2e.cjs'), '--host', options.host, '--port', String(options.port), '--debugger-flow'], { stdio: 'inherit' });
  const [code, signal] = await once(child, 'close');
  assert.equal(signal, null, 'Harmony CDP E2E was terminated by a signal');
  assert.equal(code, 0, 'Harmony CDP E2E failed');
}

function isClosedEndpointError(error) {
  return ['ECONNRESET', 'ECONNREFUSED', 'EPIPE'].includes(error?.code);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  assert.ok(process.env.HDC, 'set HDC to the Harmony hdc executable');
  assert.ok(process.env.HDC_SERIAL, 'set HDC_SERIAL to the Harmony target');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'jsbay-harmony-driver-'));
  try {
    const version = await getVersion(options.host, options.port);
    assert.equal(version.statusCode, 200, `CDP /json/version status: ${version.statusCode}`);
    await runE2E(options);

    const liveLayout = await dumpLayout(directory, 'live');
    const liveTexts = textNodes(liveLayout).map(attributes => attributes.text);
    assert.ok(liveTexts.includes(`CDP ${options.devicePort}`), `expected live UI port CDP ${options.devicePort}, got ${JSON.stringify(liveTexts.filter(text => typeof text === 'string' && text.startsWith('CDP ')))}`);
    const point = stopButton(liveLayout);
    hdc(['shell', 'uitest', 'uiInput', 'click', String(point.x), String(point.y)]);

    await assert.rejects(() => getVersion(options.host, options.port), isClosedEndpointError, 'CDP endpoint did not reject with a closed-connection error after Stop');
    const closedLayout = await dumpLayout(directory, 'closed');
    const closedTexts = textNodes(closedLayout).map(attributes => attributes.text);
    assert.ok(closedTexts.includes('CDP 0'), `expected closed UI port CDP 0, got ${JSON.stringify(closedTexts.filter(text => typeof text === 'string' && text.startsWith('CDP ')))}`);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
  process.stdout.write('PASS Harmony UI CDP port and Stop lifecycle\n');
}

main().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
