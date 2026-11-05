# Upstream provenance

This local override is based on `sqlite3_flutter_libs` 0.5.42.

- Official Pub archive: https://pub.dev/api/archives/sqlite3_flutter_libs-0.5.42.tar.gz
- Archive SHA-256: `eeb9e3a45207649076b808f8a5a74d68770d0b7f26ccef6d5f43106eee5375ad`
- The upstream license is retained in `LICENSE`.

The wrapper is unchanged apart from its native build configuration. The
withdrawn SQLite 3.52.0 dependency is replaced with the official **3.54.1**
amalgamation on Android, iOS, macOS, Linux and Windows. The 3.54.1 archive was
downloaded from sqlite.org; `sqlite3.c` matched the official release's SHA3-256
before the source/header were copied unmodified into this package.

See `sqlite-source.lock.json` for the official URL, archive SHA-256, source ID,
official source SHA3-256 and per-file SHA-256. CMake and the local CSQLite pod
verify the vendored files before configuring. CI verifies the same manifest
offline. All native builds use this one source/header pair; Android no longer
resolves a Maven SQLite library, CocoaPods uses a local dynamic CSQLite pod, and
SwiftPM explicitly depends on the dynamic product of a nested local CSQLite
package, with no remote dependencies.

Both Apple Podfiles must map `CSQLite` to this package's `darwin` directory. The
framework name matches `package:sqlite3`'s existing native loader, so the bundled
SQLite is selected before Apple's system library. Native Apple compilation and
runtime framework loading still require macOS/Xcode validation.

Compilation retains the upstream FTS5, RTree, DBSTAT, math, session/preupdate,
DQS=0 and threading options. All platforms explicitly use `SQLITE_THREADSAFE=1`.
Column metadata support is enabled; its incompatible `SQLITE_OMIT_DECLTYPE`
optimization is removed, preserving type introspection instead of omitting it.
The SwiftPM target retains GNU C11, the math linker dependency and Apple's
ambiguous-macro diagnostic workaround. Linux retains its allocator/string
feature defines. CMake optimization settings remain platform-specific; Android
uses NDK r28c and 16 KB/RELRO/NOW linker options.
