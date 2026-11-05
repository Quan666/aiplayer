#!/usr/bin/env python3
"""Check native cache identity before reusing a locally built Android JAR."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ABIS = ("armeabi-v7a", "arm64-v8a", "x86", "x86_64")


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verify(directory: Path, abi: str, api: int, *, root: Path = ROOT) -> None:
    if abi not in ABIS or api not in (23, 24):
        raise ValueError("Unsupported Android native ABI or API")
    jar = directory / f"full-{abi}.jar"
    manifest = directory / f"full-{abi}.json"
    if any(path.is_symlink() or not path.is_file() for path in (jar, manifest)):
        raise ValueError("Native JAR and metadata must be regular files")
    source_lock = root / "packages/media_kit_libs_android_video/native/sources.lock.json"
    lock = json.loads(source_lock.read_text())
    for name, expected in lock["patches"].items():
        if digest(source_lock.parent / "patches" / name) != expected:
            raise ValueError(f"Native patch hash mismatch: {name}")
    metadata = json.loads(manifest.read_text())
    expected = {
        "abi": abi,
        "api": api,
        "sourcesLockSha256": digest(source_lock),
        "recipeSha256": digest(root / "scripts/build_android_native.py"),
        "sha256": digest(jar),
    }
    if not isinstance(metadata, dict) or any(metadata.get(key) != value for key, value in expected.items()):
        raise ValueError("Native ABI, API, source lock, recipe or JAR hash changed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--abi", choices=ABIS, required=True)
    parser.add_argument("--api", type=int, choices=(23, 24), required=True)
    args = parser.parse_args()
    try:
        verify(args.directory, args.abi, args.api)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Native cache miss ({args.abi}, API {args.api}): {error}\n")
    print(f"Verified native cache: {args.abi}, API {args.api}")


if __name__ == "__main__":
    main()
