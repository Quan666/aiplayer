# Native dependency integrity

The local Linux media and Windows media overrides share
`verified_download.cmake`. Build-time downloads require HTTPS with certificate
verification, a 180-second total timeout and 30-second inactivity timeout. Both
new and cached archives must match the repository's SHA-256 pin. A mismatch stops
the build; removing the rejected cache entry allows a fresh download.

Every CMake configure recreates extracted sources and prebuilt libraries from the
verified archive. Existing extracted directories or marker files are never used
as proof of integrity. Compiler outputs remain in separate build directories.
These checks operate only at build time and do not run on the Flutter UI isolate.

The archives below were downloaded from their official HTTPS distribution
endpoints on 2026-11-04. The media archives also matched the MD5 values in the
original, SHA-256-verified Pub packages. Per-package Pub archive provenance and
licenses are retained in each override's `UPSTREAM.md` and `LICENSE`.

| Archive | SHA-256 |
| --- | --- |
| [mimalloc 2.1.2](https://codeload.github.com/microsoft/mimalloc/tar.gz/refs/tags/v2.1.2) | `2b1bff6f717f9725c70bf8d79e4786da13de8a270059e4ba0bdd262ae7be46eb` |
| [Windows libmpv 2023-09-24](https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z) | `dce982222d7a23e4a1c6f0fb6cc39f6e899a6714624b95ea49cff6558ee97572` |
| [Windows ANGLE v1.0.1](https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z) | `cc5911bb15d596fd5a2b362613ad35b7093b427117269a7359054a65746a5f9a` |

The Windows library versions remain upstream's older pinned versions. Stronger
integrity checks prevent unexpected artifact replacement; they do not fix
vulnerabilities already present in those binaries. An upgrade still requires a
maintained build and native playback validation.

SQLite no longer downloads native code at build time. All five platforms compile
the same official 3.54.1 source/header vendored in `../sqlite3_flutter_libs`, with
provenance and offline integrity checks in `sqlite-source.lock.json`.
