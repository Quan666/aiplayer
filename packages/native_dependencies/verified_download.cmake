# Shared by the repository's native dependency overrides. Do not substitute a
# cached directory for a verified archive: restored build caches are untrusted.
include_guard(GLOBAL)

function(aiplayer_verify_archive archive expected_sha256)
  string(LENGTH "${expected_sha256}" digest_length)
  if(NOT digest_length EQUAL 64 OR expected_sha256 MATCHES "[^0-9a-fA-F]")
    message(FATAL_ERROR "Invalid SHA-256 pin for ${archive}")
  endif()
  if(NOT EXISTS "${archive}" OR IS_DIRECTORY "${archive}" OR IS_SYMLINK "${archive}")
    message(FATAL_ERROR "Native dependency archive is missing or not a regular file: ${archive}")
  endif()
  file(SHA256 "${archive}" actual_sha256)
  if(NOT actual_sha256 STREQUAL expected_sha256)
    message(FATAL_ERROR "SHA-256 mismatch for ${archive}. Remove the untrusted cache entry and rebuild.")
  endif()
endfunction()

function(aiplayer_download_verified url expected_sha256 archive)
  if(NOT url MATCHES "^https://")
    message(FATAL_ERROR "Native dependency downloads require HTTPS: ${url}")
  endif()
  if(EXISTS "${archive}" OR IS_SYMLINK "${archive}")
    aiplayer_verify_archive("${archive}" "${expected_sha256}")
    return()
  endif()
  get_filename_component(archive_directory "${archive}" DIRECTORY)
  file(MAKE_DIRECTORY "${archive_directory}")
  set(partial "${archive}.part")
  file(REMOVE "${partial}")
  file(DOWNLOAD "${url}" "${partial}"
    TLS_VERIFY ON
    TIMEOUT 180
    INACTIVITY_TIMEOUT 30
    STATUS download_status)
  list(GET download_status 0 download_code)
  if(NOT download_code EQUAL 0)
    file(REMOVE "${partial}")
    message(FATAL_ERROR "Native dependency download failed: ${url}: ${download_status}")
  endif()
  file(SHA256 "${partial}" actual_sha256)
  if(NOT actual_sha256 STREQUAL expected_sha256)
    file(REMOVE "${partial}")
    message(FATAL_ERROR "SHA-256 mismatch for downloaded native dependency: ${url}")
  endif()
  file(RENAME "${partial}" "${archive}")
endfunction()

function(aiplayer_extract_verified archive expected_sha256 destination)
  aiplayer_verify_archive("${archive}" "${expected_sha256}")
  # Recreate sources/binaries from the verified bytes on each configure. Merely
  # checking a stamp would let a restored or modified extraction bypass hashes.
  set(staging "${destination}.unpack")
  file(REMOVE_RECURSE "${staging}")
  file(MAKE_DIRECTORY "${staging}")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${archive}"
    WORKING_DIRECTORY "${staging}"
    RESULT_VARIABLE extract_result
    ERROR_VARIABLE extract_error)
  if(NOT extract_result EQUAL 0)
    file(REMOVE_RECURSE "${staging}")
    message(FATAL_ERROR "Native dependency extraction failed: ${extract_error}")
  endif()
  file(REMOVE_RECURSE "${destination}")
  file(RENAME "${staging}" "${destination}")
endfunction()
