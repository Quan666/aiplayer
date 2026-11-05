"""Exercise legacy preflight and native cache reuse without compiling an APK."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_native", ROOT / "scripts/verify_android_native.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class LegacyEntryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.trace = self.root / "calls"
        self.cache = self.root / ".local-build/native-player/artifacts-api23"
        self.native = self.root / "packages/media_kit_libs_android_video/native"
        self.write("compat/android6/toolchain.json", json.dumps({"flutter": "3.32.8", "dart": "3.8.1"}))
        self.write("compat/android6/pubspec.lock", "reviewed Pub lock")
        self.write("compat/android6/verification-metadata.xml", "reviewed Gradle metadata")
        self.write("selected-sdk.json", json.dumps({"frameworkVersion": "3.32.8", "dartSdkVersion": "3.8.1"}))
        self.write(".local-build/signing/debug.keystore", "fixture key, never read")
        self.write("packages/media_kit_libs_android_video/native/patches/fixture.patch", "locked patch")
        self.write("packages/media_kit_libs_android_video/native/sources.lock.json", json.dumps({
            "patches": {"fixture.patch": hashlib.sha256(b"locked patch").hexdigest()},
        }))
        for script in ("package_android_legacy.sh", "local_build_env.sh", "verify_android_native.py"):
            target = self.root / "scripts" / script
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "scripts" / script, target)
        self.write("tools/flutter", '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
with Path(os.environ['TEST_TRACE']).open('a') as trace:
    trace.write('flutter ' + ' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['--version', '--machine']:
    print((root / 'selected-sdk.json').read_text())
''', executable=True)
        self.write("scripts/prepare_android_legacy.py", '''import os, sys
from pathlib import Path
with Path(os.environ['TEST_TRACE']).open('a') as trace:
    trace.write('prepare\\n')
if os.environ.get('TEST_PREPARE_FAIL'):
    raise SystemExit('source adaptation changed')
output = Path(sys.argv[sys.argv.index('--output') + 1])
(output / 'client').mkdir(parents=True, exist_ok=True)
(output / 'scripts').mkdir(parents=True, exist_ok=True)
(output / 'scripts/package.py').write_text("import os\\nfrom pathlib import Path\\nwith Path(os.environ['TEST_TRACE']).open('a') as trace: trace.write('package\\\\n')\\n")
''')
        self.write("scripts/build_android_native.py", '''import argparse, hashlib, json, os
from pathlib import Path
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--api', type=int)
parser.add_argument('--abi')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
with Path(os.environ['TEST_TRACE']).open('a') as trace:
    trace.write('native ' + args.abi + '\\n')
args.output.mkdir(parents=True, exist_ok=True)
jar = args.output / ('full-' + args.abi + '.jar')
jar.write_bytes(b'new compiled fixture')
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
metadata = dict(abi=args.abi, api=args.api, sha256=digest(jar),
    sourcesLockSha256=digest(root / 'packages/media_kit_libs_android_video/native/sources.lock.json'),
    recipeSha256=digest(Path(__file__)))
jar.with_suffix('.json').write_text(json.dumps(metadata))
''')
        self.environment = {
            **os.environ,
            "TEST_TRACE": str(self.trace),
            "AIPLAYER_LEGACY_FLUTTER": "tools/flutter",
            "AIPLAYER_ANDROID_NATIVE_DIR": str(self.cache),
        }
        self.environment.pop("TEST_PREPARE_FAIL", None)
        for abi in ("armeabi-v7a", "arm64-v8a"):
            self.cached(abi)

    def write(self, name, contents, *, executable=False):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
        if executable:
            target.chmod(0o755)

    def cached(self, abi):
        self.cache.mkdir(parents=True, exist_ok=True)
        jar = self.cache / f"full-{abi}.jar"
        jar.write_bytes(b"verified compiled fixture")
        manifest = {
            "abi": abi, "api": 23, "sha256": verifier.digest(jar),
            "sourcesLockSha256": verifier.digest(self.native / "sources.lock.json"),
            "recipeSha256": verifier.digest(self.root / "scripts/build_android_native.py"),
        }
        jar.with_suffix(".json").write_text(json.dumps(manifest))

    def invoke(self, *arguments):
        return subprocess.run(["bash", "scripts/package_android_legacy.sh", *arguments],
                              cwd=self.root, env=self.environment, text=True, capture_output=True)

    def calls(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def test_valid_native_cache_is_reused_after_preflight(self):
        result = self.invoke("--no-android-alias")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), ["flutter --version --machine", "prepare",
                                       "flutter pub get --enforce-lockfile", "package"])

    def test_corrupt_cached_jar_rebuilds_only_affected_abi(self):
        (self.cache / "full-armeabi-v7a.jar").write_bytes(b"corrupt cache")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls()[-2:], ["native armeabi-v7a", "package"])
        self.assertNotIn("native arm64-v8a", self.calls())
        verifier.verify(self.cache, "armeabi-v7a", 23, root=self.root)

    def test_wrong_sdk_stops_before_snapshot_and_native_build(self):
        self.write("selected-sdk.json", json.dumps({"frameworkVersion": "3.47.7", "dartSdkVersion": "3.13.5"}))
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require Flutter 3.32.8 / Dart 3.8.1", result.stderr)
        self.assertEqual(self.calls(), ["flutter --version --machine"])

    def test_missing_lock_stops_before_tools_run(self):
        (self.root / "compat/android6/verification-metadata.xml").unlink()
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dependency lock/configuration is missing", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_source_drift_stops_before_native_build(self):
        self.environment["TEST_PREPARE_FAIL"] = "1"
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), ["flutter --version --machine", "prepare"])

    def test_skip_build_is_rejected_before_snapshot_changes(self):
        result = self.invoke("--skip-build")
        self.assertEqual(result.returncode, 2)
        self.assertIn("package an existing build", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_metadata_identity_fields_must_all_match(self):
        manifest = self.cache / "full-arm64-v8a.json"
        original = json.loads(manifest.read_text())
        for field, value in (("abi", "armeabi-v7a"), ("api", 24),
                             ("sourcesLockSha256", "0" * 64), ("recipeSha256", "0" * 64),
                             ("sha256", "0" * 64)):
            with self.subTest(field=field):
                manifest.write_text(json.dumps({**original, field: value}))
                with self.assertRaises(ValueError):
                    verifier.verify(self.cache, "arm64-v8a", 23, root=self.root)

    def test_patch_drift_and_symlink_cannot_reuse_cache(self):
        patch = self.native / "patches/fixture.patch"
        patch.write_text("changed patch")
        with self.assertRaisesRegex(ValueError, "patch hash mismatch"):
            verifier.verify(self.cache, "arm64-v8a", 23, root=self.root)
        patch.write_text("locked patch")
        jar = self.cache / "full-arm64-v8a.jar"
        saved = self.cache / "saved.jar"
        jar.rename(saved)
        jar.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, "regular files"):
            verifier.verify(self.cache, "arm64-v8a", 23, root=self.root)


if __name__ == "__main__":
    unittest.main()
