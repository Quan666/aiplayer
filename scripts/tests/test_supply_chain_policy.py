"""Reject a substituted executable or a dependency verification bypass."""

from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import json

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from check_supply_chain import check


class SupplyChainPolicyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in [".github/workflows", "client/android/gradle", "packages/sqlite3_flutter_libs"]:
            shutil.copytree(ROOT / name, self.root / name)
        for name in ["server/Dockerfile", "client/android/settings.gradle.kts"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def test_substituted_wrapper_is_rejected(self):
        jar = self.root / "client/android/gradle/wrapper/gradle-wrapper.jar"
        jar.write_bytes(jar.read_bytes() + b"unreviewed executable payload")
        self.assertTrue(any("Wrapper JAR does not match" in error for error in check(self.root)))

    def test_movable_action_reference_is_rejected(self):
        workflow = self.root / ".github/workflows/substitution.yml"
        workflow.write_text("steps:\n  - uses: attacker/setup@v2\n")
        self.assertTrue(any("full commit SHA" in error for error in check(self.root)))

    def test_global_artifact_trust_cannot_bypass_checksums(self):
        metadata = self.root / "client/android/gradle/verification-metadata.xml"
        metadata.write_text(metadata.read_text().replace(
            "<configuration>",
            '<configuration><trusted-artifacts><trust group=".*" regex="true"/></trusted-artifacts>',
            1,
        ))
        self.assertTrue(any("trusted-artifacts" in error for error in check(self.root)))

    def test_tagged_container_cannot_replace_pinned_base(self):
        dockerfile = self.root / "server/Dockerfile"
        dockerfile.write_text("FROM golang:latest AS source\nFROM source AS test\nFROM scratch\n")
        errors = [error for error in check(self.root) if "Dockerfile" in error]
        self.assertEqual(len(errors), 1, errors)

    def test_modified_sqlite_source_is_rejected(self):
        source = next((self.root / "packages/sqlite3_flutter_libs").rglob("sqlite3.c"))
        source.write_bytes(source.read_bytes() + b"\n/* substituted source */\n")
        self.assertTrue(any("SQLite SHA-256 mismatch" in error for error in check(self.root)))

    def test_platform_flag_cannot_hide_an_unpinned_container(self):
        (self.root / "server/Dockerfile").write_text("FROM --platform=linux/amd64 golang:latest AS source\n")
        self.assertTrue(any("FROM syntax" in error for error in check(self.root)))

    def test_source_lock_cannot_omit_the_sqlite_header(self):
        path = self.root / "packages/sqlite3_flutter_libs/sqlite-source.lock.json"
        lock = json.loads(path.read_text())
        lock["files"] = {name: value for name, value in lock["files"].items() if name.endswith(".c")}
        path.write_text(json.dumps(lock))
        self.assertTrue(any("public header" in error for error in check(self.root)))


if __name__ == "__main__":
    unittest.main()
