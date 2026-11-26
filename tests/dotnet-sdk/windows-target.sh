#!/usr/bin/env bash
set -euo pipefail

runner_arch=${RUNNER_ARCH:-$(uname -m)}
case "$runner_arch" in
  X64|x86_64|amd64|AMD64) zig_arch=x86_64 ;;
  ARM64|aarch64|arm64) zig_arch=aarch64 ;;
  *) printf 'unsupported Windows runner architecture: %s\n' "$runner_arch" >&2; exit 64 ;;
esac

printf '%s-windows-gnu\n' "$zig_arch"
