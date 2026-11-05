"""Exercise the CI build/sign/download contract without SDKs or secrets."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
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
        (self.root / "client/pubspec.lock").write_text("reviewed-lock")
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
registrant = Path('android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java')
if sys.argv[1:3] == ['pub', 'get']:
    Path('.dart_tool').mkdir(exist_ok=True)
    Path('.dart_tool/package_config.json').write_text('{}')
    registrant.parent.mkdir(parents=True, exist_ok=True)
    registrant.write_text('dev.flutter.plugins.integration_test.IntegrationTestPlugin')
elif sys.argv[1:3] == ['build', 'apk'] and '--config-only' in sys.argv:
    assert '--pub' in sys.argv and '--no-pub' not in sys.argv
    assert '--release' in sys.argv
    if os.environ.get('CI_TEST_CONFIG_FAIL'):
        raise SystemExit('configuration failed')
    registrant.parent.mkdir(parents=True, exist_ok=True)
    registrant.write_text('release plugins')
    if os.environ.get('CI_TEST_LOCK_DRIFT'):
        Path('pubspec.lock').write_text('changed-lock')
elif sys.argv[1:3] == ['build', 'apk']:
    if not registrant.is_file() or 'integration_test' in registrant.read_text():
        raise SystemExit('release references a dev plugin')
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
(output/'client/pubspec.lock').write_text('reviewed-legacy-lock')
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
        configurations = [c for c in calls if '--config-only' in c['args']]
        self.assertEqual(len(configurations), 2)
        builds = [c for c in calls if c['args'][:2] == ['build', 'apk'] and '--config-only' not in c['args']]
        for configure, build in zip(configurations, builds):
            self.assertEqual(configure['args'], [a if a != '--no-pub' else '--pub' for a in build['args']] + ['--config-only'])
            self.assertLess(calls.index(configure), calls.index(build))
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
        self.assertIn('--config-only', calls[-2]['args'])
        self.assertIn('--pub', calls[-2]['args'])
        self.assertIn('--no-pub', calls[-1]['args'])
        self.assertEqual(calls[-1]['api'], '23')
        self.assertIn('android-arm,android-arm64', calls[-1]['args'])
        self.assertEqual(calls[-1]['cwd'], str(self.root / 'temp/android6-source/client'))
        self.assertEqual((self.root / 'temp/unsigned-apks/android-legacy/app-release.apk').read_text(), '23')

    def test_standalone_arm64_regenerates_after_locked_resolution(self):
        result = self.run_build('android-arm64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[0]['args'], ['pub', 'get', '--enforce-lockfile'])
        self.assertIn('--config-only', self.calls()[1]['args'])
        self.assertIn('--split-per-abi', self.calls()[-1]['args'])

    def test_configuration_failure_or_lock_drift_stops_before_compile_and_transfer(self):
        for target in ('android', 'android-arm64', 'android-legacy'):
            for flag in ('CI_TEST_CONFIG_FAIL', 'CI_TEST_LOCK_DRIFT'):
                with self.subTest(target=target, flag=flag):
                    self.trace.unlink(missing_ok=True)
                    (self.root / 'client/pubspec.lock').write_text('reviewed-lock')
                    self.environment[flag] = 'true'
                    try:
                        result = self.run_build(target)
                    finally:
                        self.environment.pop(flag)
                    self.assertNotEqual(result.returncode, 0)
                    if flag == 'CI_TEST_LOCK_DRIFT':
                        self.assertIn('changed pubspec.lock', result.stderr)
                    builds = [c for c in self.calls() if c['args'][:2] == ['build', 'apk']]
                    self.assertTrue(builds)
                    self.assertTrue(all('--config-only' in c['args'] for c in builds))
                    self.assertFalse((self.root / 'temp/unsigned-apks').exists())

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


class LegacyMetadataTest(unittest.TestCase):
    def test_legacy_classpath_metadata_matches_reviewed_modern_checksums(self):
        ns = {'v': 'https://schema.gradle.org/dependency-verification'}
        def pins(path):
            root = ET.parse(path).getroot()
            self.assertEqual(root.findtext('v:configuration/v:verify-metadata', namespaces=ns), 'true')
            self.assertFalse(root.findall('v:configuration/v:trusted-artifacts/v:trust', ns))
            return {
                (c.get('group'), c.get('name'), c.get('version'), a.get('name')):
                    {h.get('value') for h in a.findall('v:sha256', ns)}
                for c in root.findall('v:components/v:component', ns)
                for a in c.findall('v:artifact', ns)
            }
        modern = pins(ROOT / 'client/android/gradle/verification-metadata.xml')
        legacy = pins(ROOT / 'compat/android6/verification-metadata.xml')
        for key in (
            ('com.google.guava', 'guava-parent', '33.3.1-jre', 'guava-parent-33.3.1-jre.pom'),
            ('org.junit', 'junit-bom', '5.10.2', 'junit-bom-5.10.2.module'),
            ('org.junit', 'junit-bom', '5.9.2', 'junit-bom-5.9.2.module'),
            ('org.junit', 'junit-bom', '5.9.3', 'junit-bom-5.9.3.module'),
            ('org.junit', 'junit-bom', '5.11.0-M2', 'junit-bom-5.11.0-M2.module'),
            ('org.junit', 'junit-bom', '5.13.1', 'junit-bom-5.13.1.module'),
            ('org.junit', 'junit-bom', '5.13.4', 'junit-bom-5.13.4.module'),
            ('org.jetbrains.kotlinx', 'kotlinx-coroutines-bom', '1.8.0', 'kotlinx-coroutines-bom-1.8.0.pom'),
        ):
            with self.subTest(artifact=key):
                self.assertTrue(modern[key])
                self.assertEqual(legacy[key], modern[key])


if __name__ == "__main__":
    unittest.main()
