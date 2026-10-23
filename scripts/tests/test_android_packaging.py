"""Keep the pinned signing certificate enforced before copying release APKs."""

import importlib.util
import itertools
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
        for abi in ("arm64", "universal"):
            for keep_alias, certificate in itertools.product((True, False), (expected, "b2" * 32)):
                with self.subTest(abi=abi, keep_alias=keep_alias, certificate=certificate), tempfile.TemporaryDirectory() as directory:
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
                        "abis": ["arm64-v8a"] if abi == "arm64" else ["armeabi-v7a", "arm64-v8a", "x86_64"],
                        "version_name": "1.0.0",
                    }
                    with patch.object(packager, "ROOT", root), patch.object(packager, "CLIENT", client), \
                         patch.dict(sys.modules, {"validate_apk": validator}):
                        if certificate == expected:
                            files, details = packager.android_package(output, abi, "1.0.0+1", keep_alias=keep_alias)
                            expected_names = [f"aiplayer-1.0.0-android{'-arm64' if abi == 'arm64' else ''}.apk"]
                            if keep_alias:
                                expected_names.insert(0, "aiplayer-android-arm64-release.apk" if abi == "arm64" else "aiplayer-android-release.apk")
                            self.assertEqual([path.name for path in files], expected_names)
                            self.assertEqual(sorted(output.iterdir()), sorted(files))
                            self.assertTrue(all(path.read_bytes() == source.read_bytes() for path in files))
                            self.assertEqual(details["apk_validation"]["certificate_sha256"], expected)
                        else:
                            with self.assertRaisesRegex(RuntimeError, "signing certificate changed") as error:
                                packager.android_package(output, abi, "1.0.0+1", keep_alias=keep_alias)
                            self.assertIn(expected, str(error.exception))
                            self.assertIn(certificate, str(error.exception))
                            self.assertEqual(list(output.iterdir()), [])
                    validator.validate_apk.assert_called_once_with(source, abi=abi, expected_version="1.0.0+1")


if __name__ == "__main__":
    unittest.main()
