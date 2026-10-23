"""Exercise secret restoration with a disposable key, never the release key."""

import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "restore_android_signing", Path(__file__).resolve().parents[1] / "restore_android_signing.py"
)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class RestoreSigningTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="aiplayer-test-key-")
        cls.addClassCleanup(cls.fixture.cleanup)
        source = Path(cls.fixture.name) / "fixture.keystore"
        subprocess.run(
            ["keytool", "-genkeypair", "-keystore", str(source), "-storepass", "android",
             "-keypass", "android", "-alias", "androiddebugkey", "-keyalg", "RSA",
             "-keysize", "2048", "-validity", "1", "-dname", "CN=Disposable CI test"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        cls.key = source.read_bytes()
        cert = subprocess.check_output(
            ["keytool", "-exportcert", "-keystore", str(source), "-storepass", "android",
             "-alias", "androiddebugkey"], stderr=subprocess.PIPE,
        )
        cls.fingerprint = hashlib.sha256(cert).hexdigest()

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aiplayer-signing-test-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "signing").mkdir()
        self.pin = root / "signing/android-certificate.sha256"
        self.pin.write_text(self.fingerprint)
        self.output = root / "restored/debug.keystore"
        self.addCleanup(patch.stopall)
        patch.object(signing, "ROOT", root).start()
        patch.dict(os.environ, {
            "ANDROID_KEYSTORE_BASE64": base64.b64encode(self.key).decode(),
            "AIPLAYER_ANDROID_KEYSTORE": str(self.output),
        }).start()

    def test_valid_key_is_restored_with_private_permissions(self):
        signing.restore()
        self.assertEqual(self.output.read_bytes(), self.key)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)

    def test_missing_secret_does_not_create_key(self):
        os.environ.pop("ANDROID_KEYSTORE_BASE64")
        with self.assertRaisesRegex(ValueError, "Configure repository secret"):
            signing.restore()
        self.assertFalse(self.output.exists())

    def test_invalid_base64_does_not_create_key(self):
        os.environ["ANDROID_KEYSTORE_BASE64"] = "not!base64"
        with self.assertRaisesRegex(ValueError, "not valid Base64"):
            signing.restore()
        self.assertFalse(self.output.exists())

    def test_different_certificate_is_rejected_and_removed(self):
        self.pin.write_text("0" * 64)
        with self.assertRaisesRegex(ValueError, "does not match"):
            signing.restore()
        self.assertFalse(self.output.exists())

    def test_invalid_keystore_is_removed(self):
        os.environ["ANDROID_KEYSTORE_BASE64"] = base64.b64encode(b"not a keystore").decode()
        with self.assertRaisesRegex(ValueError, "does not match"):
            signing.restore()
        self.assertFalse(self.output.exists())

    def test_existing_key_is_never_overwritten(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"existing key")
        with self.assertRaises(FileExistsError):
            signing.restore()
        self.assertEqual(self.output.read_bytes(), b"existing key")


if __name__ == "__main__":
    unittest.main()
