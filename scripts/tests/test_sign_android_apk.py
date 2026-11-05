"""Protect the signing boundary without ever accessing the release key."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("sign_android_apk", SCRIPTS / "sign_android_apk.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SignAndroidApkTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aiplayer-sign-boundary-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "client").mkdir()
        (self.root / "client/pubspec.yaml").write_text("version: 1.2.3+45\n")
        (self.root / "signing").mkdir()
        (self.root / "signing/android-certificate.sha256").write_text("a1" * 32)
        self.directory = self.root / "unsigned"
        self.directory.mkdir()
        self.output = self.root / "artifacts"
        self.key = None
        self.addCleanup(patch.stopall)
        patch.object(signing, "ROOT", self.root).start()
        patch.dict(os.environ, {"ANDROID_KEYSTORE_BASE64": "disposable-secret"}).start()
        patch.object(signing, "sdk_tool", side_effect=lambda name: Path("/sdk") / name).start()

    def apk(self, abi="universal", names=("AndroidManifest.xml",)):
        path = self.directory / ("app-arm64-v8a-release.apk" if abi == "arm64" else "app-release.apk")
        with warnings.catch_warnings(), zipfile.ZipFile(path, "w") as archive:
            warnings.simplefilter("ignore", UserWarning)
            for name in names:
                archive.writestr(name, b"test data")
        return path

    def restore(self, *, encoded, destination):
        self.assertEqual(encoded, "disposable-secret")
        self.assertNotIn("ANDROID_KEYSTORE_BASE64", os.environ)
        self.key = destination
        destination.parent.mkdir()
        destination.write_bytes(b"disposable key fixture")

    def launch(self, command, **kwargs):
        self.assertNotIn("ANDROID_KEYSTORE_BASE64", os.environ)
        if command[0].endswith("zipalign"):
            Path(command[-1]).write_bytes(b"aligned APK")
        else:
            self.assertEqual(command[1], "sign")
            self.assertEqual(Path(command[command.index("--ks") + 1]).read_bytes(), b"disposable key fixture")
            Path(command[command.index("--out") + 1]).write_bytes(b"signed APK")

    def validate(self, path, **kwargs):
        self.assertFalse(self.key.exists(), "The key must be deleted before parsing the APK")
        self.assertEqual(kwargs["expected_version"], "1.2.3+45")
        return {"certificate_sha256": "a1" * 32}

    def test_success_preserves_variant_names_and_removes_key_before_validation(self):
        for abi in ("universal", "arm64"):
            with self.subTest(abi=abi):
                self.apk(abi)
                os.environ["ANDROID_KEYSTORE_BASE64"] = "disposable-secret"
                with patch.object(signing, "restore", side_effect=self.restore), \
                     patch.object(signing.subprocess, "run", side_effect=self.launch), \
                     patch.object(signing, "validate_apk", side_effect=self.validate):
                    result = signing.sign(self.directory, self.output, abi)
                self.assertEqual(result.name, "aiplayer-1.2.3-android" + ("-arm64" if abi == "arm64" else "") + ".apk")
                self.assertEqual(result.read_bytes(), b"signed APK")
                self.assertFalse(self.key.exists())
                next(self.directory.iterdir()).unlink()

    def test_signing_failure_removes_key_and_never_emits_artifact(self):
        self.apk()
        def launch(command, **kwargs):
            self.launch(command, **kwargs)
            if command[1] == "sign":
                raise subprocess.CalledProcessError(1, command)
        with patch.object(signing, "restore", side_effect=self.restore), \
             patch.object(signing.subprocess, "run", side_effect=launch), \
             patch.object(signing, "validate_apk") as validate:
            with self.assertRaises(subprocess.CalledProcessError):
                signing.sign(self.directory, self.output, "universal")
        self.assertFalse(self.key.exists())
        self.assertFalse(self.output.exists())
        self.assertNotIn("ANDROID_KEYSTORE_BASE64", os.environ)
        validate.assert_not_called()

    def test_legacy_signing_keeps_variant_and_strict_validation(self):
        self.apk()
        with patch.object(signing, "restore", side_effect=self.restore), \
             patch.object(signing.subprocess, "run", side_effect=self.launch), \
             patch.object(signing, "validate_apk", side_effect=self.validate) as validate:
            result = signing.sign(self.directory, self.output, "universal", android_legacy=True)
        self.assertEqual(result.name, "aiplayer-1.2.3-android-legacy.apk")
        self.assertTrue(validate.call_args.kwargs["android_legacy"])
        self.assertEqual(validate.call_args.kwargs["abi"], "universal")
        self.assertFalse(self.key.exists())

    def test_legacy_arm64_only_is_rejected_before_secret_use(self):
        with patch.object(signing, "restore") as restore, patch.object(signing.subprocess, "run") as launch:
            with self.assertRaisesRegex(ValueError, "both ARM32 and ARM64"):
                signing.sign(self.directory, self.output, "arm64", android_legacy=True)
        restore.assert_not_called()
        launch.assert_not_called()
        self.assertNotIn("ANDROID_KEYSTORE_BASE64", os.environ)

    def test_bad_certificate_is_never_published(self):
        self.apk()
        with patch.object(signing, "restore", side_effect=self.restore), \
             patch.object(signing.subprocess, "run", side_effect=self.launch), \
             patch.object(signing, "validate_apk", return_value={"certificate_sha256": "b2" * 32}):
            with self.assertRaisesRegex(ValueError, "certificate changed"):
                signing.sign(self.directory, self.output, "universal")
        self.assertFalse(self.key.exists())
        self.assertFalse(self.output.exists())

    def test_ambiguous_artifact_directory_is_rejected_before_using_secret(self):
        self.apk()
        (self.directory / "unexpected.py").write_text("raise SystemExit('never execute')")
        with patch.object(signing, "restore") as restore, patch.object(signing.subprocess, "run") as launch:
            with self.assertRaisesRegex(ValueError, "exactly one"):
                signing.sign(self.directory, self.output, "universal")
        restore.assert_not_called()
        launch.assert_not_called()

    def test_traversal_and_duplicate_zip_names_are_rejected(self):
        for names in (("../escape",), ("/escape",), ("dir\\escape",), ("duplicate", "duplicate")):
            with self.subTest(names=names):
                self.apk(names=names)
                with self.assertRaisesRegex(ValueError, "unsafe ZIP paths"):
                    signing.input_apk(self.directory, "universal")

    def test_symlink_artifact_is_rejected(self):
        source = self.apk()
        other = self.root / "external.apk"
        source.rename(other)
        source.symlink_to(other)
        with self.assertRaisesRegex(ValueError, "regular"):
            signing.input_apk(self.directory, "universal")


if __name__ == "__main__":
    unittest.main()
