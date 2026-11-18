# Source from a Hermes rebuild script. Defines hermes_compilejs_static_libs <build-dir>
# which prints absolute paths of libcompileJS.a and the compiler static libraries
# needed to link hermes::compileJS into libhermes_bridge.so.
# Usage: mapfile -t HERMES_COMPILEJS_LIBS < <(hermes_compilejs_static_libs "$BUILD")
hermes_compilejs_static_libs() {
  local build="${1:?hermes cmake build dir}"
  local compilejs=""
  local cand
  for cand in \
    "$build/API/hermes/libcompileJS.a" \
    "$build/lib/libcompileJS.a"; do
    if [[ -f "$cand" ]]; then compilejs="$cand"; break; fi
  done
  if [[ -z "$compilejs" ]]; then
    echo "ERROR: libcompileJS.a not found under $build (is the compileJS target built?)" >&2
    return 1
  fi
  # Order matches Hermes' own hermesvm link (compiler/frontend first, LLVM last).
  # Paths are under the CMake build tree; missing members fail the caller.
  local rels=(
    lib/BCGen/HBC/libhermesHBCBackend.a
    lib/BCGen/libhermesBackend.a
    lib/libhermesFrontend.a
    lib/FrontEndDefs/libhermesFrontEndDefs.a
    lib/libhermesOptimizer.a
    lib/SourceMap/libhermesSourceMap.a
    lib/Parser/libhermesParser.a
    lib/AST/libhermesAST.a
    lib/Regex/libhermesRegex.a
    lib/Inst/libhermesInst.a
    lib/ADT/libhermesADT.a
    public/hermes/Public/libhermesPublic.a
    lib/Support/libhermesSupport.a
    external/dtoa/libdtoa.a
    lib/Platform/Unicode/libhermesPlatformUnicode.a
    lib/Platform/libhermesPlatform.a
    external/llvh/lib/Support/libLLVHSupport.a
    external/llvh/lib/Demangle/libLLVHDemangle.a
  )
  printf '%s\n' "$compilejs"
  local r p
  for r in "${rels[@]}"; do
    p="$build/$r"
    if [[ ! -f "$p" ]]; then
      echo "ERROR: missing $p" >&2
      return 1
    fi
    printf '%s\n' "$p"
  done
}
