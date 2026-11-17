cmake_minimum_required(VERSION 3.20)
project(zapfastohos LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# The Rust host is built by harmonyos/build.sh and placed here before hvigor
# runs. DevEco Studio builds the ArkTS and C++ sides but not Cargo, so this
# file must exist before the IDE's native build can link. Run
# `./harmonyos/build.sh` once (or point this cache variable at a library built
# elsewhere) and the IDE build then works.
set(ZAPFAST_RUST_LIB
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/libzapfast_ohos.a"
    CACHE FILEPATH "The Rust host's static library (libzapfast_ohos.a)")

if(NOT EXISTS "${ZAPFAST_RUST_LIB}")
    message(FATAL_ERROR
        "The Rust host is missing: ${ZAPFAST_RUST_LIB}. "
        "Build it once with ./harmonyos/build.sh (which needs the "
        "aarch64-unknown-linux-ohos Rust toolchain), or set "
        "-DZAPFAST_RUST_LIB=<path to libzapfast_ohos.a>.")
endif()

add_library(zapfastohos SHARED napi_init.cpp)

target_link_libraries(zapfastohos PUBLIC
    ${ZAPFAST_RUST_LIB}
    libace_napi.z.so
    libace_ndk.z.so
    libhilog_ndk.z.so
    EGL
    GLESv3
    z
    dl
    m
    pthread
)

target_link_options(zapfastohos PRIVATE
    -Wl,--exclude-libs,ALL
    -Wl,--gc-sections
)
