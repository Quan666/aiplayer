# Android video libraries with PGS subtitles

This local package preserves the Android Java glue and plugin registration from
[`media_kit_libs_android_video` 1.3.8](https://pub.dev/packages/media_kit_libs_android_video/versions/1.3.8).
Its MIT license is included in `LICENSE`.

The upstream plugin selects the `default` libmpv build, whose FFmpeg decoder
allowlist excludes `pgssub`. Matroska can therefore expose a PGS subtitle track
even though Android cannot decode or display it. Enabling `libass` alone does not
add the missing bitmap decoder.

`android/build.gradle` instead downloads the official
[`libmpv-android-video-build` v1.1.8 full artifacts](https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.8)
for all four upstream Android ABIs. Each artifact is pinned by the SHA-256 digest
published with that release. Downloads are Gradle task outputs, verified before
use, and reused on subsequent builds. They stay in the ignored build directory;
no changes to a developer's Pub cache are required.

The [full build configuration](https://github.com/media-kit/libmpv-android-video-build/blob/v1.1.8/buildscripts/flavors/full.sh)
enables all FFmpeg decoders, including `ff_pgssub_decoder`, and retains
`--disable-gpl --disable-nonfree`. It uses the same FFmpeg 6.0 and mpv core revision
as v1.1.7. Its 64-bit native libraries retain 16 KB ELF load alignment. The
additional decoders increase each compressed native library by about 2 MB.

The app pins this package through `client/pubspec.yaml` dependency overrides.
Build it using the normal Android packaging command; no separate preparation is
required. APK validation checks that the packaged `libmpv.so` defines the PGS
decoder symbol, so changing the native dependency cannot silently remove support.
