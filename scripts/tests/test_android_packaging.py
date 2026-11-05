"""Keep the pinned signing certificate enforced before copying release APKs."""

import importlib.util
import itertools
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "packager", Path(__file__).resolve().parents[1] / "package.py"
)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class AndroidPackagingTest(unittest.TestCase):
    def test_only_pinned_certificate_can_be_packaged(self):
        expected = "a1" * 32
        for abi, legacy in (("arm64", False), ("universal", False), ("universal", True)):
            for keep_alias, certificate in itertools.product((True, False), (expected, "b2" * 32)):
                with self.subTest(abi=abi, legacy=legacy, keep_alias=keep_alias, certificate=certificate), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    client = root / "client"
                    (root / "signing").mkdir()
                    (root / "signing/android-certificate.sha256").write_text(expected + "\n")
                    source = client / "build/app/outputs/flutter-apk" / (
                        "app-arm64-v8a-release.apk" if abi == "arm64" else "app-release.apk"
                    )
                    source.parent.mkdir(parents=True)
                    source.write_bytes(b"validated APK fixture")
                    output = root / "artifacts"
                    output.mkdir()
                    validator = Mock()
                    validator.validate_apk.return_value = {
                        "certificate_sha256": certificate,
                        "abis": ["armeabi-v7a", "arm64-v8a"] if legacy else (["arm64-v8a"] if abi == "arm64" else ["armeabi-v7a", "arm64-v8a", "x86_64"]),
                        "version_name": "1.0.0",
                    }
                    with patch.object(packager, "ROOT", root), patch.object(packager, "CLIENT", client), \
                         patch.dict(sys.modules, {"validate_apk": validator}):
                        if certificate == expected:
                            files, details = packager.android_package(output, abi, "1.0.0+1", keep_alias=keep_alias, android_legacy=legacy)
                            suffix = "-legacy" if legacy else ("-arm64" if abi == "arm64" else "")
                            expected_names = [f"aiplayer-1.0.0-android{suffix}.apk"]
                            if keep_alias:
                                expected_names.insert(0, f"aiplayer-android{suffix}-release.apk")
                            self.assertEqual([path.name for path in files], expected_names)
                            self.assertEqual(sorted(output.iterdir()), sorted(files))
                            self.assertTrue(all(path.read_bytes() == source.read_bytes() for path in files))
                            self.assertEqual(details["apk_validation"]["certificate_sha256"], expected)
                            self.assertEqual(details["minimum_android"], "6.0 (API 23)" if legacy else "7.0 (API 24)")
                        else:
                            with self.assertRaisesRegex(RuntimeError, "signing certificate changed") as error:
                                packager.android_package(output, abi, "1.0.0+1", keep_alias=keep_alias, android_legacy=legacy)
                            self.assertIn(expected, str(error.exception))
                            self.assertIn(certificate, str(error.exception))
                            self.assertEqual(list(output.iterdir()), [])
                    validator.validate_apk.assert_called_once_with(source, abi=abi, expected_version="1.0.0+1", android_legacy=legacy)

    def test_legacy_build_and_metadata_do_not_replace_modern_outputs(self):
        for skip_build in (False, True):
            with self.subTest(skip_build=skip_build), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                client = root / "client"
                client.mkdir()
                (client / "pubspec.yaml").write_text("version: 1.0.0+1\n")
                output = root / "artifacts"
                output.mkdir()
                modern_metadata = output / "build-android.json"
                modern_metadata.write_text("modern metadata")
                artifact = output / "aiplayer-1.0.0-android-legacy.apk"
                artifact.write_bytes(b"validated legacy APK")
                argv = ["package.py", "android", "--android-legacy", "--output-dir", str(output)]
                if skip_build:
                    argv.append("--skip-build")
                with patch.object(packager, "CLIENT", client), patch.object(sys, "argv", argv), \
                     patch.object(packager, "run", return_value=json.dumps({"frameworkVersion": "3.32.8"})) as run, \
                     patch.object(packager, "android_package", return_value=([artifact], {"minimum_android": "6.0 (API 23)"})) as package:
                    packager.main()
                if skip_build:
                    run.assert_not_called()
                else:
                    self.assertEqual(run.call_count, 2)
                    command = run.call_args.args[0]
                    self.assertEqual(command[command.index("--target-platform") + 1], "android-arm,android-arm64")
                    self.assertEqual(run.call_args.kwargs["env"]["AIPLAYER_ANDROID_MIN_SDK"], "23")
                package.assert_called_once_with(output, "universal", "1.0.0+1", keep_alias=True, android_legacy=True)
                self.assertEqual(modern_metadata.read_text(), "modern metadata")
                metadata = json.loads((output / "build-android-legacy.json").read_text())
                self.assertEqual(metadata["minimum_android"], "6.0 (API 23)")
                self.assertEqual(metadata["artifacts"], [artifact.name])
                self.assertIn(artifact.name, (output / "SHA256SUMS-android-legacy").read_text())

    def test_legacy_rejects_modern_flutter_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            client = Path(directory)
            (client / "pubspec.yaml").write_text("version: 1.0.0+1\n")
            with patch.object(packager, "CLIENT", client), \
                 patch.object(sys, "argv", ["package.py", "android", "--android-legacy"]), \
                 patch.object(packager, "run", return_value=json.dumps({"frameworkVersion": "3.47.7"})) as run:
                with self.assertRaisesRegex(RuntimeError, "pinned Flutter 3.32.8"):
                    packager.main()
            self.assertEqual(run.call_count, 1)

    def test_legacy_cannot_silently_omit_32_bit_arm(self):
        with self.assertRaisesRegex(ValueError, "both ARM32 and ARM64"):
            packager.android_package(Path("unused"), "arm64", "1.0.0+1", android_legacy=True)


if __name__ == "__main__":
    unittest.main()
