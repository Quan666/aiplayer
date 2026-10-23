#!/usr/bin/env bash
# Source this file to reuse the project's persistent local build environment.
AIPLAYER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export AIPLAYER_BUILD_ROOT="$AIPLAYER_ROOT/.local-build"
export AIPLAYER_FLUTTER="$AIPLAYER_BUILD_ROOT/sdk/flutter/bin/flutter"
export ANDROID_HOME="$AIPLAYER_BUILD_ROOT/sdk/android"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_USER_HOME="$AIPLAYER_BUILD_ROOT/cache/android"
export PUB_CACHE="$AIPLAYER_BUILD_ROOT/cache/pub"
export GRADLE_USER_HOME="$AIPLAYER_BUILD_ROOT/cache/gradle"
export XDG_CONFIG_HOME="$AIPLAYER_BUILD_ROOT/config"
export XDG_CACHE_HOME="$AIPLAYER_BUILD_ROOT/cache"
export TMPDIR="$AIPLAYER_BUILD_ROOT/tmp"
export AIPLAYER_ANDROID_KEYSTORE="$AIPLAYER_BUILD_ROOT/signing/debug.keystore"
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export PATH="$AIPLAYER_BUILD_ROOT/sdk/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
mkdir -p "$ANDROID_USER_HOME" "$PUB_CACHE" "$GRADLE_USER_HOME" \
  "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
