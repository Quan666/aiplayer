cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "sqlite3_flutter_libs")
project(${PROJECT_NAME} LANGUAGES C CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "sqlite3_flutter_libs_plugin")

# Essentially, the idea of this build script is to compile a sqlite3.dll
# and make Fluter bundle that with the final app.
# It looks like we can't avoid building a sqlite3_flutter_libs.dll too,
# but that's not on me.

add_library(${PLUGIN_NAME} SHARED
  "sqlite3_flutter_libs_plugin.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

get_filename_component(AIPLAYER_PACKAGE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." REALPATH)
include("${AIPLAYER_PACKAGE_ROOT}/cmake/sqlite3_source.cmake")


add_library(sqlite3 SHARED "sqlite3_flutter.c")

aiplayer_configure_sqlite(sqlite3)
target_compile_options(sqlite3 PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O2>" "/w")

# Ensure sqlite3 actually gets build
add_dependencies(${PLUGIN_NAME} sqlite3)

# List of absolute paths to libraries that should be bundled with the plugin
set(sqlite3_flutter_libs_bundled_libraries
  "$<TARGET_FILE:sqlite3>"
  PARENT_SCOPE
)
