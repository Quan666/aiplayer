#!/usr/bin/env bash
set -euo pipefail
for legacy_argument in "$@"; do
  case "$legacy_argument" in
    --skip-build|--skip-build=*)
      echo "This entry recreates the Android 6 source snapshot and cannot use --skip-build. To package an existing build, run: python3 .local-build/android6/source/scripts/package.py android --android-legacy --skip-build --output-dir artifacts" >&2
      exit 2
      ;;
  esac
done
source "$(dirname -- "${BASH_SOURCE[0]}")/local_build_env.sh"
legacy_flutter="${AIPLAYER_LEGACY_FLUTTER:-$AIPLAYER_BUILD_ROOT/sdk/flutter-legacy/bin/flutter}"
if [[ ! -x "$legacy_flutter" ]]; then
  echo "Install the verified Flutter 3.32.8 SDK at .local-build/sdk/flutter-legacy (see compat/android6/README.md)." >&2
  exit 1
fi
legacy_flutter="$(cd -- "$(dirname -- "$legacy_flutter")" && pwd)/$(basename -- "$legacy_flutter")"
python3 - "$AIPLAYER_ROOT" "$legacy_flutter" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

config = Path(sys.argv[1]) / "compat/android6"
for name in ("toolchain.json", "pubspec.lock", "verification-metadata.xml"):
    if not (config / name).is_file():
        raise SystemExit(f"Android 6 dependency lock/configuration is missing: {config / name}")
expected = json.loads((config / "toolchain.json").read_text())
actual = json.loads(subprocess.check_output([sys.argv[2], "--version", "--machine"], text=True))
if actual.get("frameworkVersion") != expected["flutter"] or actual.get("dartSdkVersion") != expected["dart"]:
    raise SystemExit(f"Android 6 builds require Flutter {expected['flutter']} / Dart {expected['dart']}; select the pinned SDK with AIPLAYER_LEGACY_FLUTTER")
PY
if [[ ! -f "$AIPLAYER_ANDROID_KEYSTORE" ]]; then
  echo "Restore the existing Android signing key before building." >&2
  exit 1
fi
export AIPLAYER_FLUTTER="$legacy_flutter"
export AIPLAYER_ANDROID_MIN_SDK=23
export AIPLAYER_ANDROID_NATIVE_DIR
AIPLAYER_ANDROID_NATIVE_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' \
  "${AIPLAYER_ANDROID_NATIVE_DIR:-$AIPLAYER_BUILD_ROOT/native-player/artifacts-api23}")"
legacy_source="$AIPLAYER_BUILD_ROOT/android6/source"
python3 "$AIPLAYER_ROOT/scripts/prepare_android_legacy.py" --output "$legacy_source"
(
  cd "$legacy_source/client"
  "$legacy_flutter" pub get --enforce-lockfile
)
for legacy_abi in armeabi-v7a arm64-v8a; do
  if ! python3 "$AIPLAYER_ROOT/scripts/verify_android_native.py" \
      --api 23 --abi "$legacy_abi" --directory "$AIPLAYER_ANDROID_NATIVE_DIR"; then
    python3 "$AIPLAYER_ROOT/scripts/build_android_native.py" --api 23 --abi "$legacy_abi" --output "$AIPLAYER_ANDROID_NATIVE_DIR"
    python3 "$AIPLAYER_ROOT/scripts/verify_android_native.py" \
      --api 23 --abi "$legacy_abi" --directory "$AIPLAYER_ANDROID_NATIVE_DIR"
  fi
done
python3 "$legacy_source/scripts/package.py" android --android-legacy \
  --flutter "$legacy_flutter" --output-dir "$AIPLAYER_ROOT/artifacts" "$@"
