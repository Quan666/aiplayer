# Android video native libraries

The Java glue and Flutter plugin registration come from
[`media_kit_libs_android_video` 1.3.8](https://pub.dev/packages/media_kit_libs_android_video/versions/1.3.8).
Its MIT license is in `LICENSE`. The native components keep their own licenses;
the plugin license does not relicense mpv, FFmpeg, or the other libraries.

The upstream Android releases through `v1.1.11` still build FFmpeg 6.0. Updating
that release number therefore does not apply later FFmpeg security fixes. This
package builds native libraries from the exact upstream archives and SHA-256
values in [`native/sources.lock.json`](native/sources.lock.json), including the
FFmpeg 6.1 maintenance commit `30e346c76f01657f16398ddf9a93035c14ddb956`.
The mpv core remains at the original `78d43740f52db817d98bcf24fb30a76ab6fa13ff`
commit (`0.36.0-549`); it is not reverted to the older 0.36.0 release tag.
The source pin also updates the TLS, XML, AV1 and subtitle/font dependencies.
Upstream VCS version probes are isolated from the application repository, and
version strings come from the locked component identities.

The full non-GPL configuration retains PGS, text subtitles, Android MediaCodec,
network protocols, and all FFmpeg decoders, demuxers and parsers. Builds use the
locked NDK r28c and 16 KB ELF load alignment. The build validates PGS, JNI and
MediaCodec symbols, ELF architecture, load alignment, and the native dependency
closure before writing an artifact. Debug sections are removed without removing
capability symbols. The upstream 32-bit x86 `--disable-asm` exception and ARMv7
NEON/Cortex-A8 compiler flags are preserved.

Build on Linux with Python 3.12+, NDK `28.2.13676358`, and the distribution tools
`cmake meson ninja-build nasm autoconf automake libtool pkg-config patch build-essential`:

```sh
python3 scripts/build_android_native.py --abi arm64-v8a --output .local-build/native-player/artifacts
```

Android 7 / API 24 remains the default. The Android 6 compatibility build uses
the same locked sources with an API 23 toolchain target for every component:

```sh
python3 scripts/build_android_native.py --api 23 --abi armeabi-v7a
python3 scripts/build_android_native.py --api 23 --abi arm64-v8a
```

API 23 defaults to `.local-build/native-player/artifacts-api23`; work directory
fingerprints also include the API level. Set `AIPLAYER_ANDROID_MIN_SDK=23` during
the compatible Flutter build so the plugin selects API 23 and its artifacts.
This does not make a current Flutter engine compatible with Android 6: the app
must use the separately pinned legacy Flutter SDK and compatible plugins.

The other supported ABIs are `armeabi-v7a`, `x86` and `x86_64`. `--ndk` selects
the NDK directory; `ANDROID_NDK_HOME` and `ANDROID_NDK_ROOT` are also supported.
`--jobs` bounds compiler concurrency (default 2). `--cache-dir` may retain source
archives: every archive is hashed again before extraction. Extracted sources and
compiled objects are rebuilt in a fresh per-ABI work directory.

For CI, the native build runs without signing credentials, before APK assembly.
Set `AIPLAYER_ANDROID_NATIVE_DIR` to the directory containing `full-<abi>.jar`
and `full-<abi>.json` from that run. Gradle checks the JAR digest and the source
lock/recipe digests, ABI and API level even when Gradle considers prior outputs up to date. Missing
or mismatched provided artifacts fail the build. Local builds generate missing
artifacts from the same source recipe; there is no fallback to the old FFmpeg
6.0 binaries. The requested Flutter target platforms limit which ABIs are built.

The compatibility patches under `native/patches` preserve media-kit's JNI,
DASH URL escaping, and HLS seek behavior. Their contents are hashed in the source
lock. Patches must apply without fuzz, or be demonstrably present already;
patch failures stop the build. These patches derive from the official
[`media-kit` Android build](https://github.com/media-kit/libmpv-android-video-build/tree/v1.1.11/buildscripts/patches).

Source archives, component versions and hashes are recorded in each artifact's
JSON metadata. Keep this recipe, source lock, patches, component license notices
and corresponding sources available when distributing the native binaries.
