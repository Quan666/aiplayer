#!/usr/bin/env bash
# Unsigned CI staging only. Signing happens on a fresh runner.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${AIPLAYER_ANDROID_UNSIGNED:-}" != true ]]; then
  echo 'Unsigned staging is restricted to GitHub Actions.' >&2
  exit 2
fi
if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" || -n "${AIPLAYER_ANDROID_KEYSTORE:-}" ]]; then
  echo 'Build dependencies must not receive the persistent signing key.' >&2
  exit 2
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:?Missing Android target}"
flutter="${AIPLAYER_FLUTTER:-flutter}"
client="$root/client"
case "$target" in
  android) platforms=android-arm,android-arm64,android-x64; api=24; source_apk=app-release.apk ;;
  android-arm64) platforms=android-arm64; api=24; source_apk=app-arm64-v8a-release.apk ;;
  android-legacy)
    platforms=android-arm,android-arm64; api=23; source_apk=app-release.apk
    python3 - "$root" "$flutter" <<'PY'
import json, subprocess, sys
from pathlib import Path
expected = json.loads((Path(sys.argv[1]) / 'compat/android6/toolchain.json').read_text())
actual = json.loads(subprocess.check_output([sys.argv[2], '--version', '--machine'], text=True))
if (actual.get('frameworkVersion'), actual.get('dartSdkVersion')) != (expected['flutter'], expected['dart']):
    raise SystemExit('Legacy APK requires the pinned Flutter / Dart SDK, not just a lower minSdk')
PY
    python3 "$root/scripts/prepare_android_legacy.py" --output "$RUNNER_TEMP/android6-source"
    client="$RUNNER_TEMP/android6-source/client"
    ;;
  *) echo "Unsupported CI Android target: $target" >&2; exit 2 ;;
esac
export AIPLAYER_ANDROID_MIN_SDK="$api"
cd "$client"
# Resolve with the reviewed lock before generating release-mode tooling.
if [[ "$target" != android-arm64 || ! -f .dart_tool/package_config.json ]]; then
  "$flutter" pub get --enforce-lockfile
fi
args=(build apk --release --no-pub --target-platform "$platforms")
if [[ "$target" == android-arm64 ]]; then
  args+=(--split-per-abi --android-project-arg=force-version-code-ignoring-abi=true)
fi
# --no-pub skips release plugin regeneration in both pinned Flutter SDKs.
# pub get registers dev plugins (including integration_test), while Gradle
# excludes them from the release classpath. Regenerate through Flutter first.
# https://github.com/flutter/flutter/issues/169336
lock_checksum="$(sha256sum pubspec.lock)"
"$flutter" "${args[@]/--no-pub/--pub}" --config-only
if ! printf '%s\n' "$lock_checksum" | sha256sum --check --status; then
  echo 'Release configuration changed pubspec.lock; review dependencies before building.' >&2
  exit 1
fi
"$flutter" "${args[@]}"
mkdir -p "$RUNNER_TEMP/unsigned-apks/$target"
cp "build/app/outputs/flutter-apk/$source_apk" "$RUNNER_TEMP/unsigned-apks/$target/$source_apk"
