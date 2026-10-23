cmake_minimum_required(VERSION 3.10)
project(aiplayer_smb LANGUAGES C)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
foreach(feature ENABLE_EXAMPLES ENABLE_UTILS ENABLE_LIBKRB5 ENABLE_GSSAPI ENABLE_LIBDCERPC ENABLE_LIBQUIC ENABLE_RDMA)
  set(${feature} OFF CACHE BOOL "" FORCE)
endforeach()
# libsmb2 is a private static dependency. Flutter bundles the wrapper below;
# do not install the vendor's headers or development files into /usr/local.
add_subdirectory(vendor/libsmb2 EXCLUDE_FROM_ALL)
add_library(aiplayer_smb SHARED aiplayer_smb.c)
target_include_directories(aiplayer_smb PRIVATE vendor/libsmb2/include)
target_link_libraries(aiplayer_smb PRIVATE smb2)
set_target_properties(aiplayer_smb PROPERTIES C_VISIBILITY_PRESET hidden)
