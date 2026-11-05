# Upstream provenance

This local override is based on `media_kit_libs_linux` 1.2.1.

- Official Pub archive: https://pub.dev/api/archives/media_kit_libs_linux-1.2.1.tar.gz
- Archive SHA-256: `2b473399a49ec94452c4d4ae51cfc0f6585074398d74216092bf3d54aac37ecf`
- The upstream license is retained in `LICENSE`.

Local patches replace build-time native downloads with fixed SHA-256 pins,
verified TLS and bounded timeouts. Cached archives are verified before use;
sources and prebuilt libraries are extracted again from verified archives on
every CMake configure, so an existing directory cannot bypass verification.
The shared implementation lives in `../native_dependencies/verified_download.cmake`.

Native library versions are unchanged by this override. Stronger integrity
checks do not establish that an old native library is free of vulnerabilities.
