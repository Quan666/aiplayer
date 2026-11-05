cmake_minimum_required(VERSION 3.13)
project(aiplayer_sqlite LANGUAGES C)
include("${CMAKE_CURRENT_LIST_DIR}/../../../../cmake/sqlite3_source.cmake")
add_library(sqlite3 SHARED "${AIPLAYER_SQLITE_SOURCE}")
aiplayer_configure_sqlite(sqlite3)
target_compile_options(sqlite3 PRIVATE -O2)
# Keep Android 7+ and 16 KB page-size support on all shipped ABIs.
target_link_options(sqlite3 PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384" "-Wl,-z,relro,-z,now")
