# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)

# Deal with MSVC incompatiblity
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

# Build-time archives are outside the Pub lockfile. Verify their bytes before
# extraction, including when archives were restored from a build cache.
get_filename_component(AIPLAYER_PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." REALPATH)
include("${AIPLAYER_PACKAGE_ROOT}/../native_dependencies/verified_download.cmake")

set(LIBMPV "mpv-dev-x86_64-20230924-git-652a1dd.7z")
set(LIBMPV_SHA256 "dce982222d7a23e4a1c6f0fb6cc39f6e899a6714624b95ea49cff6558ee97572")
set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")
aiplayer_download_verified(
  "https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/${LIBMPV}"
  "${LIBMPV_SHA256}" "${LIBMPV_ARCHIVE}")
aiplayer_extract_verified("${LIBMPV_ARCHIVE}" "${LIBMPV_SHA256}" "${LIBMPV_SRC}")
file(RENAME "${LIBMPV_SRC}/include/mpv" "${LIBMPV_SRC}/mpv")
file(REMOVE_RECURSE "${LIBMPV_SRC}/include")
file(RENAME "${LIBMPV_SRC}/mpv" "${LIBMPV_SRC}/include")

set(ANGLE "ANGLE.7z")
set(ANGLE_SHA256 "cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a")
set(ANGLE_ARCHIVE "${CMAKE_BINARY_DIR}/${ANGLE}")
set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")
aiplayer_download_verified(
  "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
  "${ANGLE_SHA256}" "${ANGLE_ARCHIVE}")
aiplayer_extract_verified("${ANGLE_ARCHIVE}" "${ANGLE_SHA256}" "${ANGLE_SRC}")

set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_video_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll"
  "${ANGLE_SRC}/d3dcompiler_47.dll"
  "${ANGLE_SRC}/libEGL.dll"
  "${ANGLE_SRC}/libGLESv2.dll"
  "${ANGLE_SRC}/vk_swiftshader.dll"
  "${ANGLE_SRC}/vulkan-1.dll"
  "${ANGLE_SRC}/zlib.dll"
  PARENT_SCOPE
)
