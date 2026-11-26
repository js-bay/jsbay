hermes_cmake_exe_linker_flags() {
  local platform="$1"
  local icu_lib_dir="$2"
  local existing_flags="${3:-}"
  local rpath_link_flag
  local escaped_icu_lib_dir
  if [[ "$platform" == Linux ]]; then
    printf -v escaped_icu_lib_dir '%q' "$icu_lib_dir"
    rpath_link_flag="-Wl,-rpath-link,$escaped_icu_lib_dir"
    if [[ " $existing_flags " != *" $rpath_link_flag "* ]]; then
      existing_flags="${existing_flags:+$existing_flags }$rpath_link_flag"
    fi
  fi
  printf '%s' "$existing_flags"
}

hermes_cached_cmake_exe_linker_flags() {
  local cache_file="$1"
  [[ -f "$cache_file" ]] || return 1
  grep -q '^CMAKE_EXE_LINKER_FLAGS:[^=]*=' "$cache_file" || return 1
  sed -n 's/^CMAKE_EXE_LINKER_FLAGS:[^=]*=//p' "$cache_file" | tail -n 1
}

hermes_cmake_exe_linker_flags_for_build() {
  local platform="$1"
  local icu_lib_dir="$2"
  local cache_file="$3"
  local initial_ldflags="${4:-}"
  local existing_flags
  if existing_flags="$(hermes_cached_cmake_exe_linker_flags "$cache_file")"; then
    :
  else
    existing_flags="$initial_ldflags"
  fi
  hermes_cmake_exe_linker_flags "$platform" "$icu_lib_dir" "$existing_flags"
}
