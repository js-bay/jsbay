report_ios_simulator_failure() {
    local sim_log="$1"
    local sim_status="$2"
    printf 'ERROR: iOS Simulator consumer failed with status %s; log: %s\n' "$sim_status" "$sim_log" >&2
    if [ -s "$sim_log" ]; then
        printf '%s\n' '----- iOS Simulator console output -----' >&2
        cat "$sim_log" >&2
        printf '%s\n' '----- end iOS Simulator console output -----' >&2
    else
        printf '%s\n' 'iOS Simulator console log is empty or unavailable.' >&2
    fi
}
