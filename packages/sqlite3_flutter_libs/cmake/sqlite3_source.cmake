# One audited amalgamation for every platform. No network or external resolver.
get_filename_component(AIPLAYER_SQLITE_PACKAGE "${CMAKE_CURRENT_LIST_DIR}/.." REALPATH)
set(AIPLAYER_SQLITE_SOURCE_DIR "${AIPLAYER_SQLITE_PACKAGE}/darwin/sqlite3_flutter_libs/Sources/CSQLite")
set(AIPLAYER_SQLITE_SOURCE "${AIPLAYER_SQLITE_SOURCE_DIR}/sqlite3.c")
set(AIPLAYER_SQLITE_HEADERS "${AIPLAYER_SQLITE_SOURCE_DIR}/include")
foreach(kind source header)
  if(kind STREQUAL "source")
    set(path "${AIPLAYER_SQLITE_SOURCE}")
    set(expected "0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52")
  else()
    set(path "${AIPLAYER_SQLITE_HEADERS}/sqlite3.h")
    set(expected "d6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c")
  endif()
  if(IS_SYMLINK "${path}")
    message(FATAL_ERROR "SQLite source must be a regular vendored file: ${path}")
  endif()
  file(SHA256 "${path}" actual)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "Vendored SQLite 3.54.1 SHA-256 mismatch: ${path}")
  endif()
endforeach()

function(aiplayer_configure_sqlite target)
  target_include_directories(${target} PRIVATE "${AIPLAYER_SQLITE_SOURCE_DIR}" "${AIPLAYER_SQLITE_HEADERS}")
  set_target_properties(${target} PROPERTIES C_VISIBILITY_PRESET default POSITION_INDEPENDENT_CODE ON)
  # Preserve the upstream package's database features and threading semantics.
  target_compile_definitions(${target} PRIVATE
    SQLITE_THREADSAFE=1 SQLITE_ENABLE_DBSTAT_VTAB SQLITE_ENABLE_FTS5
    SQLITE_ENABLE_RTREE SQLITE_ENABLE_MATH_FUNCTIONS SQLITE_ENABLE_COLUMN_METADATA
    SQLITE_DQS=0 SQLITE_DEFAULT_MEMSTATUS=0 SQLITE_TEMP_STORE=2
    SQLITE_MAX_EXPR_DEPTH=0 SQLITE_STRICT_SUBTYPE=1 SQLITE_OMIT_AUTHORIZATION
    SQLITE_OMIT_DEPRECATED SQLITE_OMIT_PROGRESS_CALLBACK
    SQLITE_OMIT_SHARED_CACHE SQLITE_OMIT_TCL_VARIABLE SQLITE_OMIT_TRACE
    SQLITE_USE_ALLOCA SQLITE_ENABLE_SESSION SQLITE_ENABLE_PREUPDATE_HOOK
    SQLITE_UNTESTABLE SQLITE_HAVE_ISNAN SQLITE_HAVE_LOCALTIME_R SQLITE_HAVE_LOCALTIME_S)
  if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(${target} PRIVATE -fstack-protector-strong)
  endif()
  if(UNIX AND NOT APPLE)
    target_link_libraries(${target} PRIVATE m)
  endif()
endfunction()
