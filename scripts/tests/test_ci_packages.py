"""Exercise the CI build/sign/download contract without SDKs or secrets."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_packages as ci
import sign_android_apk as signer


class PackagePlanTest(unittest.TestCase):
    def test_default_and_android_both_include_real_legacy_toolchain(self):
        for target in ("all", "android"):
            with self.subTest(target=target):
                profiles = ci.android_matrix(target)["include"]
                self.assertEqual([p["profile"] for p in profiles], ["modern", "legacy"])
                self.assertEqual(profiles[1]["flutter"], "3.32.8")
                self.assertEqual(profiles[1]["api"], 23)
                self.assertEqual(profiles[1]["abis"], "armeabi-v7a arm64-v8a")
                self.assertNotIn("x86", profiles[0]["abis"].split())

    def test_legacy_only_does_not_expand_into_modern_matrix(self):
        self.assertEqual([p["profile"] for p in ci.android_matrix("android-legacy")["include"]], ["legacy"])
        self.assertEqual(ci.android_matrix("macos"), {"include": []})


class PackageSummaryTest(unittest.TestCase):
    def test_each_download_explains_architecture_system_size_and_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            names = ["aiplayer-1.2.3-android.apk", "aiplayer-1.2.3-android-arm64.apk",
                     "aiplayer-1.2.3-android-legacy.apk", "aiplayer-macos-unsigned.zip"]
            for name in names:
                (directory / name).write_bytes(b"package fixture")
            (directory / "build-android-legacy.json").write_text('{"min_sdk":23}')
            with patch.dict(os.environ, {"LEGACY_URL": "https://github.com/example/artifacts/42"}):
                summary = ci.package_summary(directory, "all", "1.2.3+4")
            self.assertIn("Android 6.0 / 6.0.1+", summary)
            self.assertIn("https://github.com/example/artifacts/42", summary)
            self.assertIn("ARM32 / ARM64 / x86_64", summary)
            self.assertIn("仅 ARM64", summary)
            self.assertIn("MiB", summary)
            self.assertIn(ci.digest(directory / names[2]), summary)
            self.assertIn('"min_sdk": 23', summary)
            self.assertNotIn(names[3], summary)
            legacy = ci.package_summary(directory, "android-legacy", "1.2.3+4")
            self.assertNotIn(names[0], legacy)
            macos = ci.package_summary(directory, "macos", "1.2.3+4")
            self.assertIn(names[3], macos)
            self.assertIn("Apple Silicon / Intel", macos)
            self.assertIn("未公证", macos)
            (directory / names[2]).unlink()
            with self.assertRaises(ValueError):
                ci.package_summary(directory, "android", "1.2.3+4")


class SignTransferTest(unittest.TestCase):
    def test_all_variants_receive_secret_only_for_their_sign_call(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            for name in ("android", "android-arm64", "android-legacy"):
                (directory / name).mkdir()
            calls = []
            def sign(source, output, abi, *, android_legacy):
                calls.append((source.name, abi, android_legacy))
                self.assertEqual(os.environ.pop("ANDROID_KEYSTORE_BASE64"), "fixture-secret")
            with patch.dict(os.environ, {"ANDROID_KEYSTORE_BASE64": "fixture-secret"}), \
                 patch.object(signer, "sign", side_effect=sign):
                ci.sign_packages(directory, "all")
                self.assertNotIn("ANDROID_KEYSTORE_BASE64", os.environ)
            self.assertEqual(calls, [("android", "universal", False),
                                     ("android-arm64", "arm64", False),
                                     ("android-legacy", "universal", True)])

    def test_incomplete_or_extra_transfer_stops_before_accessing_signer(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "android-legacy").mkdir()
            with patch.object(signer, "sign") as sign:
                with self.assertRaises(ValueError):
                    ci.sign_packages(directory, "android")
                (directory / "unexpected").mkdir()
                with self.assertRaises(ValueError):
                    ci.sign_packages(directory, "android-legacy")
                sign.assert_not_called()

    def test_sign_failure_clears_secret_and_does_not_start_next_variant(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "android-legacy").mkdir()
            with patch.dict(os.environ, {"ANDROID_KEYSTORE_BASE64": "fixture-secret"}), \
                 patch.object(signer, "sign", side_effect=ValueError("bad APK")) as sign:
                with self.assertRaisesRegex(ValueError, "bad APK"):
                    ci.sign_packages(directory, "android-legacy")
                self.assertNotIn("ANDROID_KEYSTORE_BASE64", os.environ)
                sign.assert_called_once()


class UnsignedBuildTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        for name in ("build_release.sh", "ci_android_build.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / "client").mkdir()
        (self.root / "compat/android6").mkdir(parents=True)
        shutil.copyfile(ROOT / "compat/android6/toolchain.json", self.root / "compat/android6/toolchain.json")
        self.trace = self.root / "trace"
        flutter = self.root / "flutter"
        flutter.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ['CI_TEST_TRACE']).open('a') as output:
    output.write(json.dumps({'args':sys.argv[1:], 'cwd':str(Path.cwd()), 'api':os.environ.get('AIPLAYER_ANDROID_MIN_SDK')})+'\\n')
if sys.argv[1:] == ['--version', '--machine']:
    print(json.dumps({'frameworkVersion':os.environ.get('CI_TEST_SDK', '3.32.8'), 'dartSdkVersion':'3.8.1'}))
elif sys.argv[1:3] == ['pub', 'get']:
    Path('.dart_tool').mkdir(exist_ok=True)
    Path('.dart_tool/package_config.json').write_text('{}')
elif sys.argv[1:3] == ['build', 'apk']:
    target = Path('build/app/outputs/flutter-apk')
    target.mkdir(parents=True, exist_ok=True)
    name = 'app-arm64-v8a-release.apk' if '--split-per-abi' in sys.argv else 'app-release.apk'
    (target / name).write_text(os.environ['AIPLAYER_ANDROID_MIN_SDK'])
''')
        flutter.chmod(0o755)
        (self.root / "scripts/prepare_android_legacy.py").write_text('''import sys
from pathlib import Path
output = Path(sys.argv[sys.argv.index('--output')+1])
(output/'client').mkdir(parents=True, exist_ok=True)
''')
        self.environment = {**os.environ, "GITHUB_ACTIONS": "true", "AIPLAYER_ANDROID_UNSIGNED": "true",
                            "RUNNER_TEMP": str(self.root / "temp"), "AIPLAYER_FLUTTER": str(flutter),
                            "CI_TEST_TRACE": str(self.trace)}
        for name in ("ANDROID_KEYSTORE_BASE64", "AIPLAYER_ANDROID_KEYSTORE"):
            self.environment.pop(name, None)

    def run_build(self, target):
        return subprocess.run(["bash", "scripts/build_release.sh", target], cwd=self.root,
                              env=self.environment, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def test_modern_builds_reuse_workspace_resolve_once_and_keep_both_apks(self):
        for target in ("android", "android-arm64"):
            result = self.run_build(target)
            self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(sum(c['args'][:2] == ['pub', 'get'] for c in calls), 1)
        builds = [c for c in calls if c['args'][:2] == ['build', 'apk']]
        self.assertEqual(len(builds), 2)
        self.assertEqual(builds[0]['cwd'], builds[1]['cwd'])
        self.assertTrue(all('--no-pub' in c['args'] and c['api'] == '24' for c in builds))
        self.assertIn('--android-project-arg=force-version-code-ignoring-abi=true', builds[1]['args'])
        self.assertTrue((self.root / 'temp/unsigned-apks/android/app-release.apk').is_file())
        self.assertTrue((self.root / 'temp/unsigned-apks/android-arm64/app-arm64-v8a-release.apk').is_file())

    def test_legacy_checks_engine_builds_isolated_api23_and_enforces_lock(self):
        result = self.run_build('android-legacy')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(calls[0]['args'], ['--version', '--machine'])
        self.assertIn('--enforce-lockfile', calls[1]['args'])
        self.assertEqual(calls[-1]['api'], '23')
        self.assertIn('android-arm,android-arm64', calls[-1]['args'])
        self.assertEqual(calls[-1]['cwd'], str(self.root / 'temp/android6-source/client'))
        self.assertEqual((self.root / 'temp/unsigned-apks/android-legacy/app-release.apk').read_text(), '23')

    def test_modern_sdk_cannot_be_relabeled_as_legacy(self):
        self.environment['CI_TEST_SDK'] = '3.47.7'
        result = self.run_build('android-legacy')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pinned Flutter', result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_unsigned_build_rejects_key_exposure_and_non_ci_use(self):
        for name, value in (("ANDROID_KEYSTORE_BASE64", "fixture-secret"),
                            ("AIPLAYER_ANDROID_KEYSTORE", "/fixture/key"), ("GITHUB_ACTIONS", "false")):
            with self.subTest(name=name):
                environment = self.environment.copy()
                self.environment[name] = value
                result = self.run_build('android')
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.calls(), [])
                self.environment = environment


if __name__ == "__main__":
    unittest.main()
