cmake_minimum_required(VERSION 3.14)
project(aiplayer_smb LANGUAGES C)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
set(aiplayer_smb_bundled_libraries $<TARGET_FILE:aiplayer_smb> PARENT_SCOPE)
