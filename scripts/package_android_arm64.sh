#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/local_build_env.sh"
if [[ ! -f "$AIPLAYER_ANDROID_KEYSTORE" ]]; then
  echo "Missing persistent signing key: $AIPLAYER_ANDROID_KEYSTORE" >&2
  echo "Restore the existing key before packaging; do not generate a replacement for updates." >&2
  exit 1
fi
python3 "$AIPLAYER_ROOT/scripts/package.py" android --android-abi arm64 "$@"
