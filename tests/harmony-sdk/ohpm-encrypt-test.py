import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
script = root / 'scripts/ohpm-encrypt-passphrase.py'
with tempfile.TemporaryDirectory() as tmp:
    executable = pathlib.Path(tmp) / 'ohpm'
    executable.write_text('#!/usr/bin/env python3\nprint("Please enter the password to be encrypted:", flush=True)\nwith open("/dev/tty", "r") as terminal:\n    password = terminal.readline().strip()\nprint("security:01:abc:123" if password == "example-secret" else "invalid", flush=True)\n')
    executable.chmod(0o700)
    env = {**os.environ, 'OHPM_BIN': str(executable)}
    result = subprocess.run(['python3', str(script), str(pathlib.Path(tmp) / 'crypto')], input='example-secret\n', text=True, capture_output=True, env=env, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == 'security:01:abc:123'
    assert 'example-secret' not in result.stdout + result.stderr
