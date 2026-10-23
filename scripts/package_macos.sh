#!/usr/bin/env bash
# Certificate-free personal-use build. Run on a Mac or a GitHub macOS runner.
set -euo pipefail

AIPLAYER_APP_ONLY=false
if [[ "$#" -eq 1 && "$1" == --app-only ]]; then
  AIPLAYER_APP_ONLY=true
elif [[ "$#" -ne 0 ]]; then
  echo 'Usage: package_macos.sh [--app-only]' >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'macOS packaging requires macOS and Xcode.' >&2
  exit 1
fi

AIPLAYER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AIPLAYER_FLUTTER="${AIPLAYER_FLUTTER:-flutter}"
cd "$AIPLAYER_ROOT/client"

"$AIPLAYER_FLUTTER" config --enable-macos-desktop --no-enable-swift-package-manager --no-enable-macos-arm64-only
"$AIPLAYER_FLUTTER" pub get --enforce-lockfile

# Flutter forwards FLUTTER_XCODE_* to xcodebuild. Override only this build;
# keep the project's sandbox and provisioned keychain entitlements for signed builds.
export FLUTTER_XCODE_CODE_SIGN_IDENTITY='-'
export FLUTTER_XCODE_CODE_SIGN_STYLE=Manual
export FLUTTER_XCODE_DEVELOPMENT_TEAM=''
export FLUTTER_XCODE_CODE_SIGN_ENTITLEMENTS=''
export FLUTTER_XCODE_CODE_SIGNING_ALLOWED=YES
export FLUTTER_XCODE_CODE_SIGNING_REQUIRED=YES
export FLUTTER_XCODE_ARCHS='arm64 x86_64'
export FLUTTER_XCODE_ONLY_ACTIVE_ARCH=NO
"$AIPLAYER_FLUTTER" build macos --release --no-pub --dart-define=AIPLAYER_MACOS_ADHOC=true

AIPLAYER_APP="$AIPLAYER_ROOT/client/build/macos/Build/Products/Release/aiplayer.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$AIPLAYER_APP"
# Check every bundled Mach-O, including player/plugin libraries, not just Runner.
while IFS= read -r -d '' binary; do
  if /usr/bin/file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/lipo "$binary" -verify_arch arm64 x86_64
  fi
done < <(find "$AIPLAYER_APP/Contents" -type f -print0)

if [[ "$AIPLAYER_APP_ONLY" == true ]]; then
  # A .app is a directory bundle. Preserve permissions and framework symlinks
  # in one ZIP for CI, without building a DMG or additional metadata artifacts.
  mkdir -p "$AIPLAYER_ROOT/artifacts"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$AIPLAYER_APP" \
    "$AIPLAYER_ROOT/artifacts/aiplayer-macos-unsigned.zip"
else
  python3 "$AIPLAYER_ROOT/scripts/package.py" macos --skip-build
fi
