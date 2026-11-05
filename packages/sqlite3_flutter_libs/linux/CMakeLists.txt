cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "sqlite3_flutter_libs")
project(${PROJECT_NAME} LANGUAGES C CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "sqlite3_flutter_libs_plugin")

get_filename_component(AIPLAYER_PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." REALPATH)
include("${AIPLAYER_PACKAGE_ROOT}/cmake/sqlite3_source.cmake")


add_library(${PLUGIN_NAME} SHARED
  "sqlite3_flutter_libs_plugin.cc"
  "${AIPLAYER_SQLITE_SOURCE}"
)

# Not applying the standard settings because we compile sqlite3
# which fails with -Wall -Werror. But we apply most of them:
target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_14)
target_compile_options(${PLUGIN_NAME} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)

aiplayer_configure_sqlite(${PLUGIN_NAME})
target_compile_definitions(${PLUGIN_NAME} PRIVATE
  SQLITE_HAVE_MALLOC_USABLE_SIZE SQLITE_HAVE_STRCHRNUL)

