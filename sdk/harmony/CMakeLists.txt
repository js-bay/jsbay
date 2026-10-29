cmake_minimum_required(VERSION 3.15)
project(jsbay_harmony LANGUAGES C CXX)

# The application supplies the archive produced by `zig build -Dtarget=aarch64-linux-ohos`.
set(JSBAY_INCLUDE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../include" CACHE PATH "js-bay headers")
set(JSBAY_LIBRARY "" CACHE FILEPATH "js-bay static library for the selected Harmony ABI")
if(NOT JSBAY_LIBRARY AND DEFINED ENV{JSBAY_LIBRARY})
    set(JSBAY_LIBRARY "$ENV{JSBAY_LIBRARY}")
endif()
if(NOT JSBAY_LIBRARY)
    message(FATAL_ERROR "Set JSBAY_LIBRARY to the target-specific libjsbay.a")
endif()

add_library(jsbay_harmony SHARED src/main/cpp/jsbay_harmony.cpp)
target_compile_features(jsbay_harmony PRIVATE cxx_std_17)
target_include_directories(jsbay_harmony PRIVATE ${JSBAY_INCLUDE_DIR})
target_link_libraries(jsbay_harmony PRIVATE ${JSBAY_LIBRARY} ace_napi.z)
