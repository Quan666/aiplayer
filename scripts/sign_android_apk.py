#!/usr/bin/env python3
"""Sign a CI-built APK on a fresh runner without running its build dependencies.

The existing certificate is restored only for the signing operation and removed
before this process exits, including on validation failures. Never run Flutter,
Gradle or APK-provided code in this job.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

from restore_android_signing import restore
from validate_apk import sdk_tool, validate_apk


ROOT = Path(__file__).resolve().parents[1]


def input_apk(directory: Path, abi: str) -> Path:
    expected = "app-arm64-v8a-release.apk" if abi == "arm64" else "app-release.apk"
    entries = list(directory.iterdir())
    if len(entries) != 1 or entries[0].name != expected or not entries[0].is_file() or entries[0].is_symlink():
        raise ValueError(f"Expected exactly one regular {expected} from the current build")
    source = entries[0]
    # These artifacts cross a trust boundary. Bound parsing and reject ambiguous
    # or traversal paths before any native SDK tool or secret is involved.
    if source.stat().st_size > 512 * 1024 * 1024:
        raise ValueError("APK exceeds the 512 MiB signing limit")
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) > 20000 or sum(entry.file_size for entry in entries) > 1024 * 1024 * 1024:
            raise ValueError("APK ZIP exceeds signing limits")
        names = set()
        for entry in entries:
            parts = entry.filename.split("/")
            if entry.filename in names or ".." in parts or entry.filename.startswith("/") or "\\" in entry.filename:
                raise ValueError("APK has duplicate or unsafe ZIP paths")
            names.add(entry.filename)
    return source


def sign(directory: Path, output: Path, abi: str, *, android_legacy: bool = False) -> Path:
    # Do not pass the Base64 secret to zipalign, keytool or apksigner.
    encoded = os.environ.pop("ANDROID_KEYSTORE_BASE64", "")
    if android_legacy and abi != "universal":
        raise ValueError("Android 6 compatibility APKs must include both ARM32 and ARM64")
    source = input_apk(directory, abi)
    version = re.search(r"^version:\s*(\S+)", (ROOT / "client/pubspec.yaml").read_text(), re.MULTILINE)
    if not version or not re.fullmatch(r"[0-9A-Za-z.+_-]+", version.group(1)):
        raise ValueError("Missing or invalid source version")
    version = version.group(1)
    name = version.partition("+")[0]
    suffix = "-legacy" if android_legacy else ("-arm64" if abi == "arm64" else "")
    target = output / f"aiplayer-{name}-android{suffix}.apk"
    if target.exists():
        raise FileExistsError(f"Refusing to overwrite signed APK: {target.name}")
    # Resolve SDK tools before restoring a key, on the fresh signing runner.
    zipalign = str(sdk_tool("zipalign"))
    apksigner = str(sdk_tool("apksigner"))
    with tempfile.TemporaryDirectory(prefix="aiplayer-apk-sign-") as temporary:
        temporary = Path(temporary)
        aligned = temporary / "aligned.apk"
        signed = temporary / "signed.apk"
        key = temporary / "signing/debug.keystore"
        try:
            subprocess.run([zipalign, "-P", "16", "-f", "4", str(source), str(aligned)], check=True)
            restore(encoded=encoded, destination=key)
            encoded = ""
            subprocess.run([
                apksigner, "sign", "--ks", str(key), "--ks-key-alias", "androiddebugkey",
                "--ks-pass", "pass:android", "--key-pass", "pass:android",
                "--v1-signing-enabled", "true", "--v2-signing-enabled", "true",
                "--v3-signing-enabled", "true", "--v4-signing-enabled", "false",
                "--out", str(signed), str(aligned),
            ], check=True)
        finally:
            key.unlink(missing_ok=True)
            encoded = ""
        # Validate only after the secret is gone. Invalid APKs never reach the
        # artifact directory or a release, even if the signing command succeeded.
        validation = validate_apk(signed, abi=abi, expected_version=version, android_legacy=android_legacy)
        expected = (ROOT / "signing/android-certificate.sha256").read_text().strip()
        if validation["certificate_sha256"] != expected:
            raise ValueError("APK signing certificate changed; refusing an incompatible update")
        output.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(signed, target)
    print(f"Signed and validated {target.name}")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--abi", choices=["universal", "arm64"], required=True)
    parser.add_argument("--android-legacy", action="store_true", help="Sign and validate the Android 6 compatibility APK")
    args = parser.parse_args()
    sign(args.input_dir, args.output_dir, args.abi, android_legacy=args.android_legacy)


if __name__ == "__main__":
    main()
