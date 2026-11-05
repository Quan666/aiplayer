#!/usr/bin/env bash
# Canonical release entry; see docs/BUILDING.md.
set -euo pipefail
release_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo 'Usage: bash scripts/build_release.sh {android|android-arm64|android-legacy|macos}' >&2
  exit 2
fi
case "$1" in
  android)
    source "$release_root/scripts/local_build_env.sh"
    exec python3 "$release_root/scripts/package.py" android --no-android-alias
    ;;
  android-arm64)
    exec bash "$release_root/scripts/package_android_arm64.sh" --no-android-alias
    ;;
  android-legacy)
    exec bash "$release_root/scripts/package_android_legacy.sh" --no-android-alias
    ;;
  macos)
    exec bash "$release_root/scripts/package_macos.sh" --app-only
    ;;
  *)
    echo "Unknown release target: $1 (expected android, android-arm64, android-legacy or macos)" >&2
    exit 2
    ;;
esac
