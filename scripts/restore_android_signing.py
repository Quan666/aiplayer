#!/usr/bin/env python3
"""Restore the CI signing secret without logging it; reject a different key."""

import base64
import binascii
import hashlib
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def restore() -> None:
    encoded = os.environ.get("ANDROID_KEYSTORE_BASE64", "")
    if not encoded:
        raise ValueError("Configure repository secret ANDROID_KEYSTORE_BASE64 with the existing keystore; refusing to generate a new key")
    destination = os.environ.get("AIPLAYER_ANDROID_KEYSTORE")
    if not destination:
        raise ValueError("Set AIPLAYER_ANDROID_KEYSTORE to a temporary output path")
    try:
        data = base64.b64decode("".join(encoded.split()), validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("ANDROID_KEYSTORE_BASE64 is not valid Base64") from None
    if not data:
        raise ValueError("ANDROID_KEYSTORE_BASE64 decodes to an empty file")
    target = Path(destination)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Exclusive creation also prevents overwriting an existing local key.
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
        result = subprocess.run(
            ["keytool", "-exportcert", "-keystore", str(target),
             "-alias", "androiddebugkey", "-storepass", "android"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        expected = (ROOT / "signing/android-certificate.sha256").read_text().strip()
        if result.returncode or hashlib.sha256(result.stdout).hexdigest() != expected:
            raise ValueError("Signing certificate does not match the existing 0.5.4+ releases; restore the correct keystore")
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    print("Existing Android signing certificate verified.")


if __name__ == "__main__":
    try:
        restore()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from None
