"""Keep releases complete and safely retryable without contacting GitHub."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "publish_release", Path(__file__).resolve().parents[1] / "publish_release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

VERSION = "0.5.15+21"
TAG = "v0.5.15"
ANDROID_ASSETS = (
    "aiplayer-0.5.15-android.apk",
    "aiplayer-0.5.15-android-arm64.apk",
)
MACOS_ASSET = "aiplayer-macos-unsigned.zip"


class ReleaseVersionTest(unittest.TestCase):
    def test_pubspec_version_preserves_build_number_and_prerelease(self):
        with tempfile.TemporaryDirectory() as directory:
            pubspec = Path(directory) / "pubspec.yaml"
            for version in (VERSION, "0.5.15-rc.1+21"):
                with self.subTest(version=version):
                    pubspec.write_text(f"name: aiplayer\nversion: {version}\n")
                    self.assertEqual(release.read_version(pubspec), version)

    def test_incomplete_or_malformed_version_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            pubspec = Path(directory) / "pubspec.yaml"
            for version in (
                "", "0.5", "0.5.15", "v0.5.15+21", "0.5.15+build",
                "0.5.15+21trailing", "0.5.15-+21",
            ):
                with self.subTest(version=version):
                    pubspec.write_text(f"name: aiplayer\nversion: {version}\n")
                    with self.assertRaises(ValueError):
                        release.read_version(pubspec)
            pubspec.write_text("name: aiplayer\n")
            with self.assertRaises(ValueError):
                release.read_version(pubspec)

    def test_tag_must_match_source_version_without_build_number(self):
        release.validate_tag(TAG, VERSION)
        release.validate_tag("v0.5.15-rc.1", "0.5.15-rc.1+21")
        for tag in ("v0.5.14", "0.5.15", "v0.5.15+21", "v0.5.15-rc.1"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag, VERSION)
        with self.assertRaises(ValueError):
            release.validate_tag(TAG, "0.5.15-rc.1+21")


class ReleaseAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def write_assets(self, names):
        for name in names:
            (self.directory / name).write_bytes(b"package fixture")

    def test_only_requested_packages_are_selected(self):
        self.write_assets((*ANDROID_ASSETS, MACOS_ASSET))
        self.write_assets((
            "aiplayer-android.apk", "aiplayer-0.5.14-android.apk",
            "android-build.log", "build-android.json", "SHA256SUMS-android",
            "debug.keystore",
        ))
        for target, names in (
            ("all", (*ANDROID_ASSETS, MACOS_ASSET)),
            ("android", ANDROID_ASSETS),
            ("macos", (MACOS_ASSET,)),
        ):
            with self.subTest(target=target):
                self.assertCountEqual(
                    release.release_assets(self.directory, VERSION, target),
                    [self.directory / name for name in names],
                )

    def test_single_platform_does_not_require_other_platform_packages(self):
        self.write_assets(ANDROID_ASSETS)
        self.assertEqual(
            len(release.release_assets(self.directory, VERSION, "android")), 2
        )
        for name in ANDROID_ASSETS:
            (self.directory / name).unlink()
        self.write_assets((MACOS_ASSET,))
        self.assertEqual(
            release.release_assets(self.directory, VERSION, "macos"),
            [self.directory / MACOS_ASSET],
        )

    def test_every_requested_package_must_exist_and_be_nonempty(self):
        for target, names in (
            ("all", (*ANDROID_ASSETS, MACOS_ASSET)),
            ("android", ANDROID_ASSETS),
            ("macos", (MACOS_ASSET,)),
        ):
            for invalid_name in names:
                for invalid_state in ("missing", "empty"):
                    with self.subTest(
                        target=target, package=invalid_name, state=invalid_state
                    ):
                        self.write_assets((*ANDROID_ASSETS, MACOS_ASSET))
                        invalid = self.directory / invalid_name
                        if invalid_state == "missing":
                            invalid.unlink()
                        else:
                            invalid.write_bytes(b"")
                        with self.assertRaises(ValueError):
                            release.release_assets(self.directory, VERSION, target)


class ReleasePublishingTest(unittest.TestCase):
    assets = [Path("artifacts") / name for name in ANDROID_ASSETS]

    @staticmethod
    def github_response(*, existing=None, fail_upload=False):
        def run(command, **kwargs):
            if command[2] == "view":
                return subprocess.CompletedProcess(
                    command,
                    1 if existing is None else 0,
                    stdout="" if existing is None else json.dumps({"isDraft": existing}),
                    stderr="release not found" if existing is None else "",
                )
            if command[2] == "upload" and fail_upload:
                if kwargs.get("check"):
                    raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 1)
            return subprocess.CompletedProcess(command, 0)

        return run

    @staticmethod
    def commands(run):
        return [call.args[0] for call in run.call_args_list]

    def assert_uploaded_assets(self, command):
        self.assertIn(TAG, command)
        self.assertIn("--clobber", command)
        self.assertTrue({str(path) for path in self.assets}.issubset(command))

    def test_new_release_stays_draft_until_upload_completes(self):
        with patch.object(
            release.subprocess, "run", side_effect=self.github_response()
        ) as run:
            release.publish(TAG, self.assets)
        commands = self.commands(run)
        self.assertEqual([command[2] for command in commands], [
            "view", "create", "upload", "edit",
        ])
        self.assertIn("--draft", commands[1])
        self.assertIn("--verify-tag", commands[1])
        self.assertIn("--generate-notes", commands[1])
        self.assertNotIn("--notes-file", commands[1])
        self.assertNotIn("--prerelease", commands[1])
        self.assert_uploaded_assets(commands[2])
        self.assertIn("--draft=false", commands[3])

    def test_new_release_uses_explicit_notes_without_generated_notes(self):
        notes = Path("docs/releases") / f"{TAG}.md"
        with patch.object(
            release.subprocess, "run", side_effect=self.github_response()
        ) as run:
            release.publish(TAG, self.assets, notes=notes)
        create = self.commands(run)[1]
        self.assertEqual(create[create.index("--notes-file") + 1], str(notes))
        self.assertNotIn("--generate-notes", create)

    def test_existing_release_preserves_notes_during_upload_retry(self):
        notes = Path("docs/releases") / f"{TAG}.md"
        for existing in (True, False):
            with self.subTest(draft=existing), patch.object(
                release.subprocess, "run", side_effect=self.github_response(existing=existing)
            ) as run:
                release.publish(TAG, self.assets, notes=notes)
                for command in self.commands(run):
                    self.assertNotIn("--notes-file", command)
                    self.assertNotIn("--generate-notes", command)
                    self.assertNotEqual(command[2], "create")

    def test_published_release_can_replace_assets_without_recreating_it(self):
        with patch.object(
            release.subprocess, "run", side_effect=self.github_response(existing=False)
        ) as run:
            release.publish(TAG, self.assets)
        commands = self.commands(run)
        self.assertEqual([command[2] for command in commands], ["view", "upload"])
        self.assert_uploaded_assets(commands[1])

    def test_incomplete_draft_is_reused_and_published_after_retry(self):
        with patch.object(
            release.subprocess, "run", side_effect=self.github_response(existing=True)
        ) as run:
            release.publish(TAG, self.assets)
        commands = self.commands(run)
        self.assertEqual([command[2] for command in commands], [
            "view", "upload", "edit",
        ])
        self.assert_uploaded_assets(commands[1])
        self.assertIn("--draft=false", commands[2])

    def test_upload_failure_never_publishes_a_new_or_reused_draft(self):
        for existing in (None, True, False):
            with self.subTest(existing=existing), patch.object(
                release.subprocess,
                "run",
                side_effect=self.github_response(existing=existing, fail_upload=True),
            ) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    release.publish(TAG, self.assets)
                operations = [command[2] for command in self.commands(run)]
                self.assertEqual(operations[-1], "upload")
                self.assertNotIn("edit", operations)

    def test_prerelease_tag_creates_a_prerelease(self):
        with patch.object(
            release.subprocess, "run", side_effect=self.github_response()
        ) as run:
            release.publish("v0.5.15-rc.1", self.assets)
        create = next(command for command in self.commands(run) if command[2] == "create")
        self.assertIn("--prerelease", create)
        self.assertIn("--draft", create)


class ReleaseNotesSelectionTest(unittest.TestCase):
    def test_main_selects_only_existing_notes_for_the_validated_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "client").mkdir()
            (root / "client/pubspec.yaml").write_text(f"version: {VERSION}\n")
            notes = root / "docs/releases" / f"{TAG}.md"
            notes.parent.mkdir(parents=True)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            for name in ANDROID_ASSETS:
                (artifacts / name).write_bytes(b"package fixture")
            argv = [
                "publish_release.py", "--tag", TAG, "--target", "android",
                "--artifacts", str(artifacts),
            ]
            with patch.object(release, "ROOT", root), patch.object(sys, "argv", argv):
                for present in (False, True):
                    if present:
                        notes.write_text("弹幕列表与目录识别修复\n", encoding="utf-8")
                    with self.subTest(notes_present=present), patch.object(release, "publish") as publish:
                        release.main()
                        self.assertEqual(publish.call_args.kwargs["notes"], notes if present else None)
                argv[2] = "../outside"
                with patch.object(release, "publish") as publish, self.assertRaises(ValueError):
                    release.main()
                publish.assert_not_called()


if __name__ == "__main__":
    unittest.main()
