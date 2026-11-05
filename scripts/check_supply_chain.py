#!/usr/bin/env python3
"""Reject unpinned executable build dependencies without network access.

This checks repository policy, not whether a pinned version has new CVEs.
Dependabot and upstream security review remain necessary when updating pins.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = {"v": "https://schema.gradle.org/dependency-verification"}


def check(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    for workflow in sorted((root / ".github/workflows").glob("*.y*ml")):
        for line_number, line in enumerate(workflow.read_text().splitlines(), 1):
            match = re.match(r"\s*(?:-\s*)?uses:\s*['\"]?([^\s'\"#]+)", line)
            if match and not match[1].startswith("./"):
                if not re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", match[1]):
                    errors.append(f"{workflow.relative_to(root)}:{line_number}: pin action to a full commit SHA")

    stages: set[str] = set()
    dockerfile = root / "server/Dockerfile"
    for number, line in enumerate(dockerfile.read_text().splitlines(), 1):
        match = re.match(r"FROM\s+(\S+)(?:\s+AS\s+(\S+))?\s*$", line, re.IGNORECASE)
        if not match:
            if re.match(r"\s*FROM\b", line, re.IGNORECASE):
                errors.append(f"server/Dockerfile:{number}: unsupported FROM syntax requires pin review")
            continue
        image, stage = match.groups()
        if image != "scratch" and image not in stages and not re.fullmatch(r"[^@]+@sha256:[0-9a-f]{64}", image):
            errors.append(f"server/Dockerfile:{number}: pin base image to an immutable digest")
        if stage:
            stages.add(stage)

    wrapper = root / "client/android/gradle/wrapper"
    properties = dict(
        line.split("=", 1) for line in (wrapper / "gradle-wrapper.properties").read_text().splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    )
    if not re.fullmatch(r"[0-9a-f]{64}", properties.get("distributionSha256Sum", "")):
        errors.append("Gradle distribution requires a SHA-256 pin")
    if not properties.get("distributionUrl", "").startswith("https\\://services.gradle.org/distributions/"):
        errors.append("Gradle distribution must use the official HTTPS endpoint")
    if properties.get("validateDistributionUrl") != "true":
        errors.append("Gradle distribution URL validation must remain enabled")
    if not 0 < int(properties.get("networkTimeout", "0")) <= 120000:
        errors.append("Gradle Wrapper requires a bounded network timeout")
    jar = wrapper / "gradle-wrapper.jar"
    checksum = wrapper / "gradle-wrapper.jar.sha256"
    if not jar.is_file() or not checksum.is_file():
        errors.append("Commit the verified Gradle Wrapper JAR and its official SHA-256")
    elif hashlib.sha256(jar.read_bytes()).hexdigest() != checksum.read_text().strip():
        errors.append("Gradle Wrapper JAR does not match its official SHA-256")

    sqlite_root = root / "packages/sqlite3_flutter_libs"
    sqlite_lock = json.loads((sqlite_root / "sqlite-source.lock.json").read_text())
    required_sqlite_files = {
        "darwin/sqlite3_flutter_libs/Sources/CSQLite/sqlite3.c",
        "darwin/sqlite3_flutter_libs/Sources/CSQLite/include/sqlite3.h",
    }
    if set(sqlite_lock["files"]) != required_sqlite_files:
        errors.append("SQLite source lock must cover the amalgamation and its public header")
    if tuple(map(int, sqlite_lock["version"].split("."))) < (3, 54, 1):
        errors.append("SQLite source predates the reviewed 3.54.1 baseline")
    for relative, expected in sqlite_lock["files"].items():
        source = sqlite_root / relative
        if source.is_symlink() or not source.resolve().is_relative_to(sqlite_root.resolve()):
            errors.append(f"SQLite source must remain inside its package: {relative}")
        elif not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            errors.append(f"Vendored SQLite SHA-256 mismatch: {relative}")
        elif source.name == "sqlite3.c" and hashlib.sha3_256(source.read_bytes()).hexdigest() != sqlite_lock["sqlite3_c_sha3_256"]:
            errors.append("SQLite amalgamation differs from the official release SHA3-256")

    settings = (root / "client/android/settings.gradle.kts").read_text()
    kotlin = re.search(r'id\("org.jetbrains.kotlin.android"\) version "([^"]+)"', settings)
    if not kotlin or not re.fullmatch(r"\d+\.\d+\.\d+", kotlin[1]):
        errors.append("Use an exact stable Kotlin Gradle Plugin version")
    elif tuple(map(int, kotlin[1].split("."))) < (2, 4, 20):
        errors.append("Kotlin Gradle Plugin predates the CVE-2026-53914 fix")

    metadata = root / "client/android/gradle/verification-metadata.xml"
    if not metadata.is_file():
        errors.append("Commit Gradle dependency verification metadata")
    else:
        tree = ET.fromstring(metadata.read_text())
        if tree.findtext("v:configuration/v:verify-metadata", namespaces=NAMESPACE) != "true":
            errors.append("Gradle must verify dependency metadata")
        if tree.findall("v:configuration/v:trusted-artifacts/v:trust", NAMESPACE):
            errors.append("Do not bypass artifact checks with trusted-artifacts exclusions")
        artifacts = tree.findall("v:components/v:component/v:artifact", NAMESPACE)
        if not artifacts:
            errors.append("Gradle verification metadata has no pinned artifacts")
        for artifact in artifacts:
            hashes = artifact.findall("v:sha256", NAMESPACE)
            if not hashes or any(not re.fullmatch(r"[0-9a-f]{64}", entry.get("value", "")) for entry in hashes):
                errors.append(f"Gradle artifact lacks a valid SHA-256: {artifact.get('name')}")
    return errors


def main() -> None:
    try:
        errors = check()
    except (OSError, ValueError, KeyError, ET.ParseError) as error:
        errors = [f"Cannot verify supply chain policy: {error}"]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        raise SystemExit(1)
    print("Build dependency pins and checksums verified")


if __name__ == "__main__":
    main()
