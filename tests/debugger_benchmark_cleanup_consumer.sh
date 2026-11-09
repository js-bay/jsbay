#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" >"$JSBAY_DEBUGGER_CLEANUP_PROOF"
printf 'READY 1\n'
while :; do :; done
