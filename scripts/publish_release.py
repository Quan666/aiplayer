#!/usr/bin/env python3
"""Validate a version tag and publish the selected CI packages to GitHub."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def read_version(pubspec: Path) -> str:
    match = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\+[0-9]+)\s*$",
        pubspec.read_text(),
        re.MULTILINE,
    )
    if not match:
        raise ValueError("pubspec.yaml must contain a version such as 0.5.15+21")
    return match.group(1)


def validate_tag(tag: str, version: str) -> None:
    expected = f"v{version.split('+')[0]}"
    if tag != expected:
        raise ValueError(f"Release tag {tag!r} does not match pubspec version {version}; expected {expected}")


def release_assets(directory: Path, version: str, target: str) -> list[Path]:
    if target not in ("all", "android", "macos"):
        raise ValueError(f"Unsupported release target: {target}")
    name = version.split("+")[0]
    names = []
    if target in ("all", "android"):
        names.extend((f"aiplayer-{name}-android.apk", f"aiplayer-{name}-android-arm64.apk"))
    if target in ("all", "macos"):
        names.append("aiplayer-macos-unsigned.zip")
    assets = [directory / name for name in names]
    for asset in assets:
        if not asset.is_file() or asset.stat().st_size == 0:
            raise ValueError(f"Release package is missing or empty: {asset}")
    return assets


def publish(tag: str, assets: list[Path]) -> None:
    existing = subprocess.run(
        ["gh", "release", "view", tag, "--json", "isDraft"],
        check=False, capture_output=True, text=True,
    )
    if existing.returncode == 0:
        draft = json.loads(existing.stdout)["isDraft"]
    else:
        # A failed upload must leave a new release unpublished and retryable.
        command = ["gh", "release", "create", tag, "--draft", "--verify-tag", "--generate-notes", "--title", tag]
        if "-" in tag:
            command.append("--prerelease")
        subprocess.run(command, check=True)
        draft = True
    subprocess.run(
        ["gh", "release", "upload", tag, *(str(asset) for asset in assets), "--clobber"],
        check=True,
    )
    if draft:
        subprocess.run(["gh", "release", "edit", tag, "--draft=false"], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--target", choices=("all", "android", "macos"), default="all")
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    version = read_version(ROOT / "client/pubspec.yaml")
    validate_tag(args.tag, version)
    if args.check_only:
        print(f"Release tag {args.tag} matches {version}")
        return
    if args.artifacts is None:
        parser.error("--artifacts is required when publishing")
    assets = release_assets(args.artifacts, version, args.target)
    publish(args.tag, assets)


if __name__ == "__main__":
    main()
