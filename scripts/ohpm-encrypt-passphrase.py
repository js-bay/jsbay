#!/usr/bin/env python3
import errno
import fcntl
import os
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import time

if len(sys.argv) != 2:
    raise SystemExit('Usage: ohpm-encrypt-passphrase.py <crypto-directory>')
passphrase = sys.stdin.buffer.readline().rstrip(b'\r\n')
if not passphrase:
    raise SystemExit('A nonempty passphrase is required on standard input')

master, slave = pty.openpty()
settings = termios.tcgetattr(slave)
settings[3] &= ~termios.ECHO
termios.tcsetattr(slave, termios.TCSANOW, settings)


def attach_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


process = subprocess.Popen(
    [os.environ.get('OHPM_BIN', 'ohpm'), 'config', 'encrypt', '--crypto_path', sys.argv[1]],
    stdin=slave, stdout=slave, stderr=slave, preexec_fn=attach_terminal,
)
os.close(slave)
data = b''
sent = False
deadline = time.monotonic() + 30
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            data += chunk
            if not sent and (b'password' in data.lower() or b'passphrase' in data.lower() or '\u5bc6\u7801'.encode() in data):
                os.write(master, passphrase)
                os.write(master, b'\r')
                sent = True
        if process.poll() is not None and not ready:
            break
    if process.poll() is None:
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            raise RuntimeError('OHPM password encryption timed out') from None
    match = re.search(rb'security:[A-Za-z0-9:]+', data)
    if process.returncode != 0 or not sent or not match:
        raise RuntimeError('OHPM password encryption failed')
    sys.stdout.write(match.group().decode('ascii') + '\n')
except RuntimeError as error:
    print(error, file=sys.stderr)
    if os.environ.get('OHPM_TEST_DIAGNOSTIC') == 'true' and passphrase == b'example-passphrase':
        print(repr(data), file=sys.stderr)
    raise SystemExit(1)
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait()
    os.close(master)
