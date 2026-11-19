#!/usr/bin/env bash

jsbay_configure_jvm_ubsan_options() {
    local jvm_ubsan_options='handle_segv=0:handle_sigbus=0:handle_sigfpe=0:handle_sigill=0:handle_sigtrap=0:halt_on_error=1:abort_on_error=0'
    if [[ -n "${UBSAN_OPTIONS:-}" ]]; then
        export UBSAN_OPTIONS="${UBSAN_OPTIONS}:${jvm_ubsan_options}"
    else
        export UBSAN_OPTIONS="$jvm_ubsan_options"
    fi
}
