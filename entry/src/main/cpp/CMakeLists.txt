# Native call media module — H.264 encode/decode via OH_VideoEncoder/Decoder.
#
# The ArkTS media API has no raw real-time video codec (only AVRecorder to
# file / AVPlayer playback), so the video half of the WhatsApp-native call
# must run here in C++. This module:
#   - exposes a NAPI surface the ArkTS call service calls
#   - H.264-encodes camera frames (or YUV buffers) into Annex-B AUs
#   - H.264-decodes peer AUs for display on an XComponent surface
#
# Requires the HarmonyOS SDK (libnative_media_venc/dec + libnative_window).

cmake_minimum_required(VERSION 3.5.0)
project(call_media)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include)

# The embedded WhatsApp engine (Rust cdylib). Built by cargo:
#   cd engine && cargo build --release --target aarch64-unknown-linux-ohos
# wa_bridge.cpp exposes it to ArkTS; it is only compiled+linked once the Rust
# .so exists, so the app keeps building without it.
set(WA_ENGINE_LIB "${CMAKE_CURRENT_SOURCE_DIR}/../../../../engine/target/aarch64-unknown-linux-ohos/release/libwa_engine.so")
if(EXISTS "${WA_ENGINE_LIB}" AND CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    add_library(call_media SHARED
        video_encoder.cpp
        video_decoder.cpp
        napi_init.cpp
        wa_bridge.cpp)
    target_link_libraries(call_media PUBLIC ${WA_ENGINE_LIB})
    # The engine .so is not a CMake target, so copy it next to libcall_media.so
    # after the build; the HAP packager collects every .so in that dir.
    add_custom_command(TARGET call_media POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${WA_ENGINE_LIB}" "$<TARGET_FILE_DIR:call_media>/libwa_engine.so")
else()
    add_library(call_media SHARED
        video_encoder.cpp
        video_decoder.cpp
        napi_init.cpp)
endif()

target_link_libraries(call_media PUBLIC
    libace_napi.z.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_venc.so
    libnative_media_vdec.so
    libnative_window.so
    libhilog_ndk.z.so)
