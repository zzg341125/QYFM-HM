cmake_minimum_required(VERSION 3.5.0)
project(qyfm_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(FFMPEG_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg)
set(FFMPEG_LIB_DIR ${FFMPEG_ROOT}/lib/${OHOS_ARCH})

add_library(qyfm_ffmpeg SHARED ffmpeg_decoder.cpp)

target_link_options(qyfm_ffmpeg PRIVATE -Wl,-Bsymbolic)

target_include_directories(qyfm_ffmpeg PRIVATE
    ${FFMPEG_ROOT}/include
    ${OHOS_NDK_HOME}/sysroot/usr/include
)

target_link_directories(qyfm_ffmpeg PRIVATE ${FFMPEG_LIB_DIR})

target_link_libraries(qyfm_ffmpeg PUBLIC
    ace_napi.z
    avcodec
    swresample
    avutil
    m
)
