# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.13)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

# This is the public option enabling dynamic linking on request of applications.
option(MIMALLOC_USE_STATIC_LIBS "Whether to prefer linking to mimalloc statically" ON)

set(PROJECT_NAME "media_kit_libs_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

get_filename_component(AIPLAYER_PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." REALPATH)
include("${AIPLAYER_PACKAGE_ROOT}/../native_dependencies/verified_download.cmake")

if(MIMALLOC_USE_STATIC_LIBS)
  set(MIMALLOC_SHA256 "2b1bff6f717f9725c70bf8d79e4786da13de8a270059e4ba0bdd262ae7be46eb")
  set(MIMALLOC_ARCHIVE "${CMAKE_BINARY_DIR}/mimalloc-2.1.2.tar.gz")
  set(MIMALLOC_SRC "${CMAKE_BINARY_DIR}/aiplayer-native/mimalloc/mimalloc-2.1.2")
  set(MIMALLOC_BUILD "${CMAKE_BINARY_DIR}/mimalloc-build")
  aiplayer_download_verified(
    "https://codeload.github.com/microsoft/mimalloc/tar.gz/refs/tags/v2.1.2"
    "${MIMALLOC_SHA256}" "${MIMALLOC_ARCHIVE}")
  aiplayer_extract_verified("${MIMALLOC_ARCHIVE}" "${MIMALLOC_SHA256}"
    "${CMAKE_BINARY_DIR}/aiplayer-native/mimalloc")

  # Keep build outputs separate from the verified source extraction.
  set(MIMALLOC_LIB "${MIMALLOC_BUILD}/mimalloc.o" CACHE INTERNAL "" FORCE)
  file(GLOB_RECURSE MIMALLOC_INPUTS CONFIGURE_DEPENDS
    "${MIMALLOC_SRC}/src/*.c" "${MIMALLOC_SRC}/include/*.h")
  add_custom_command(OUTPUT "${MIMALLOC_LIB}"
    COMMAND "${CMAKE_COMMAND}" -S "${MIMALLOC_SRC}" -B "${MIMALLOC_BUILD}"
      -DCMAKE_BUILD_TYPE=Release -DMI_BUILD_SHARED=OFF -DMI_BUILD_STATIC=OFF
      -DMI_BUILD_TESTS=OFF -DMI_BUILD_OBJECT=ON
    COMMAND "${CMAKE_COMMAND}" --build "${MIMALLOC_BUILD}" --config Release
      --target mimalloc-obj-target
    DEPENDS "${MIMALLOC_ARCHIVE}" "${MIMALLOC_SRC}/CMakeLists.txt" ${MIMALLOC_INPUTS}
    VERBATIM)
  add_custom_target(MIMALLOC_TARGET ALL DEPENDS "${MIMALLOC_LIB}")
else()
  find_library(MIMALLOC_PATH "libmimalloc.so")
  if(MIMALLOC_PATH)
    set(MIMALLOC_LIB "${MIMALLOC_PATH}" CACHE INTERNAL "" FORCE)
  endif()
endif()

unset(MIMALLOC_USE_STATIC_LIBS CACHE)

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_linux_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "media_kit_libs_linux_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)

set(
  media_kit_libs_linux_bundled_libraries
  ""
  PARENT_SCOPE
)
