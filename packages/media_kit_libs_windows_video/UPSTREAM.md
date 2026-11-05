# Upstream provenance

This local override is based on `media_kit_libs_windows_video` 1.0.11.

- Official Pub archive: https://pub.dev/api/archives/media_kit_libs_windows_video-1.0.11.tar.gz
- Archive SHA-256: `dff76da2778729ab650229e6b4ec6ec111eb5151431002cbd7ea304ff1f112ab`
- The upstream license is retained in `LICENSE`.

Local patches replace build-time native downloads with fixed SHA-256 pins,
verified TLS and bounded timeouts. Cached archives are verified before use;
sources and prebuilt libraries are extracted again from verified archives on
every CMake configure, so an existing directory cannot bypass verification.
The shared implementation lives in `../native_dependencies/verified_download.cmake`.

Native library versions are unchanged by this override. Stronger integrity
checks do not establish that an old native library is free of vulnerabilities.
