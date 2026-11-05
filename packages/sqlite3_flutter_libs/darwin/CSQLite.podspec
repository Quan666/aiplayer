require 'digest'

# The local Podfile mapping supplies this pod; no remote sqlite3 version is used.
sqlite_root = File.join(__dir__, 'sqlite3_flutter_libs', 'Sources', 'CSQLite')
{
  'sqlite3.c' => '0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52',
  'include/sqlite3.h' => 'd6c84557261893439b341d2e6c35187ae3ea24fbfd843ad94616f72d89242b8c'
}.each do |relative, expected|
  path = File.join(sqlite_root, relative)
  raise "Vendored SQLite 3.54.1 SHA-256 mismatch: #{relative}" if File.symlink?(path) || Digest::SHA256.file(path).hexdigest != expected
end

Pod::Spec.new do |s|
  s.name = 'CSQLite'
  s.version = '3.54.1'
  s.summary = 'Hash-verified SQLite 3.54.1 amalgamation for AIPlayer'
  s.homepage = 'https://www.sqlite.org'
  s.license = { :type => 'Public Domain', :file => '../SQLITE_LICENSE.md' }
  s.author = 'SQLite authors'
  s.source = { :path => '.' }
  s.source_files = 'sqlite3_flutter_libs/Sources/CSQLite/sqlite3.c', 'sqlite3_flutter_libs/Sources/CSQLite/include/sqlite3.h'
  s.public_header_files = 'sqlite3_flutter_libs/Sources/CSQLite/include/sqlite3.h'
  s.module_name = 'CSQLite'
  s.static_framework = false
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.14'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_C_LANGUAGE_STANDARD' => 'gnu11',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'NO',
    'DEAD_CODE_STRIPPING' => 'NO',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) SQLITE_THREADSAFE=1 SQLITE_ENABLE_DBSTAT_VTAB SQLITE_ENABLE_FTS5 SQLITE_ENABLE_RTREE SQLITE_ENABLE_MATH_FUNCTIONS SQLITE_ENABLE_COLUMN_METADATA SQLITE_DQS=0 SQLITE_DEFAULT_MEMSTATUS=0 SQLITE_TEMP_STORE=2 SQLITE_MAX_EXPR_DEPTH=0 SQLITE_STRICT_SUBTYPE=1 SQLITE_OMIT_AUTHORIZATION SQLITE_OMIT_DEPRECATED SQLITE_OMIT_PROGRESS_CALLBACK SQLITE_OMIT_SHARED_CACHE SQLITE_OMIT_TCL_VARIABLE SQLITE_OMIT_TRACE SQLITE_USE_ALLOCA SQLITE_ENABLE_SESSION SQLITE_ENABLE_PREUPDATE_HOOK SQLITE_UNTESTABLE SQLITE_HAVE_ISNAN SQLITE_HAVE_LOCALTIME_R SQLITE_HAVE_LOCALTIME_S SQLITE_HAVE_MALLOC_USABLE_SIZE SQLITE_HAVE_STRCHRNUL'
  }
end
