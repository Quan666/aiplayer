"""Verify native reuse, publication and corruption boundaries without GitHub."""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import android_native_registry as registry


class NativeRegistryTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        native = self.root / registry.NATIVE
        (native / "patches").mkdir(parents=True)
        (native / "patches/fixture.patch").write_bytes(b"native patch")
        (native / "sources.lock.json").write_text(json.dumps({
            "ndk": "28.2.13676358", "patches": {
                "fixture.patch": hashlib.sha256(b"native patch").hexdigest(),
            },
        }))
        shutil.copyfile(ROOT / registry.NATIVE / "toolchain.json", native / "toolchain.json")
        for name in ("scripts/build_android_native.py", "scripts/verify_android_native.py",
                     "scripts/android_native_registry.py", ".github/workflows/android-native.yml"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"fixture {name}\n")
        self.environment = {"GITHUB_SHA": "a" * 40, "GITHUB_REPOSITORY": "owner/player", "GITHUB_RUN_ID": "123"}
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, self.environment).start()
        self.ident = registry.identity(self.root)
        self.bundles = self.root / "bundles"
        self.bundles.mkdir()
        self.client = registry.Registry("owner/player")

    def build_bundle(self, api=24, abi="arm64-v8a"):
        directory = self.root / f"build-{api}-{abi}"
        directory.mkdir(exist_ok=True)
        jar = directory / f"full-{abi}.jar"
        jar.write_bytes(f"compiled fixture {api} {abi}".encode())
        (directory / f"full-{abi}.json").write_text(json.dumps({
            "abi": abi, "api": api, "sha256": registry.digest(jar),
            "recipeSha256": registry.digest(self.root / "scripts/build_android_native.py"),
            "sourcesLockSha256": registry.digest(self.root / registry.NATIVE / "sources.lock.json"),
        }))
        return registry.pack(directory, self.bundles, api, abi, root=self.root)

    def all_bundles(self):
        for target in self.ident["targets"]:
            self.build_bundle(**target)

    def release(self, *, draft=False):
        return {"tag_name": self.ident["tag"], "draft": draft, "prerelease": True,
                "assets": [{"name": path.name, "size": path.stat().st_size,
                            "digest": f"sha256:{registry.digest(path)}", "state": "uploaded"}
                           for path in sorted(self.bundles.iterdir())]}

    def copy_download(self, release, asset, destination):
        path = destination / asset["name"]
        shutil.copyfile(self.bundles / asset["name"], path)
        return path

    def rewrite(self, bundle, *, record=None, members=None):
        with zipfile.ZipFile(bundle) as archive:
            data = {entry.filename: archive.read(entry) for entry in archive.infolist()}
        if record:
            payload = json.loads(data[registry.MANIFEST])
            record(payload)
            data[registry.MANIFEST] = json.dumps(payload).encode()
        if members:
            members(data)
        with zipfile.ZipFile(bundle, "w") as archive:
            for name, value in data.items():
                archive.writestr(name, value)

    def test_identity_changes_only_for_native_inputs(self):
        for name in ("client/lib/main.dart", ".github/workflows/packages.yml"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unrelated UI or application packaging change")
        self.assertEqual(registry.identity(self.root), self.ident)
        for name in ("scripts/build_android_native.py", ".github/workflows/android-native.yml",
                     f"{registry.NATIVE}/toolchain.json"):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                if name.endswith("json"):
                    data = json.loads(original)
                    data["revision"] += 1
                    path.write_text(json.dumps(data))
                else:
                    path.write_bytes(original + b"changed native executable input\n")
                self.assertNotEqual(registry.identity(self.root)["fingerprint"], self.ident["fingerprint"])
                path.write_bytes(original)
        native = self.root / registry.NATIVE
        patchfile = native / "patches/fixture.patch"
        patchfile.write_bytes(b"unreviewed patch")
        with self.assertRaisesRegex(ValueError, "patch hash mismatch"):
            registry.identity(self.root)
        source = json.loads((native / "sources.lock.json").read_text())
        source["patches"]["fixture.patch"] = registry.digest(patchfile)
        (native / "sources.lock.json").write_text(json.dumps(source))
        self.assertNotEqual(registry.identity(self.root)["fingerprint"], self.ident["fingerprint"])

    def test_bundle_round_trip_retains_api_and_abi(self):
        for target in self.ident["targets"]:
            with self.subTest(target=target):
                bundle = self.build_bundle(**target)
                output = self.root / f"output-{target['api']}"
                registry.unpack(bundle, output, **target, repo=self.client.repo, root=self.root)
                metadata = json.loads((output / f"full-{target['abi']}.json").read_text())
                self.assertEqual(metadata["api"], target["api"])
                self.assertEqual(metadata["abi"], target["abi"])

    def test_wrong_repository_fingerprint_toolchain_api_or_abi_is_rejected(self):
        for key, value in (("repository", "attacker/player"), ("fingerprint", "b" * 64),
                           ("inputs", {}), ("api", 23), ("abi", "x86_64"), ("schema", 2)):
            with self.subTest(key=key):
                bundle = self.build_bundle()
                self.rewrite(bundle, record=lambda record: record.update({key: value}))
                output = self.root / "rejected"
                with self.assertRaises(ValueError):
                    registry.unpack(bundle, output, 24, "arm64-v8a", self.client.repo, root=self.root)
                self.assertFalse(output.exists())

    def test_corrupt_jar_or_metadata_is_rejected_before_copy(self):
        for name in ("full-arm64-v8a.jar", "full-arm64-v8a.json"):
            with self.subTest(name=name):
                bundle = self.build_bundle()
                self.rewrite(bundle, members=lambda members: members.update({name: b"corrupted"}))
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    registry.unpack(bundle, self.root / "rejected", 24, "arm64-v8a", self.client.repo, root=self.root)

    def test_embedded_native_identity_is_checked_even_with_matching_bundle_checksum(self):
        bundle = self.build_bundle()
        def corrupt(members):
            name = "full-arm64-v8a.json"
            metadata = json.loads(members[name])
            metadata["recipeSha256"] = "f" * 64
            members[name] = json.dumps(metadata).encode()
            record = json.loads(members[registry.MANIFEST])
            record["files"][name] = hashlib.sha256(members[name]).hexdigest()
            members[registry.MANIFEST] = json.dumps(record).encode()
        self.rewrite(bundle, members=corrupt)
        with self.assertRaisesRegex(ValueError, "recipe or JAR hash changed"):
            registry.unpack(bundle, self.root / "rejected", 24, "arm64-v8a", self.client.repo, root=self.root)

    def test_zip_extra_traversal_duplicate_and_symlink_are_rejected(self):
        for kind in ("extra", "traversal", "duplicate", "symlink"):
            with self.subTest(kind=kind):
                bundle = self.build_bundle()
                with warnings.catch_warnings(), zipfile.ZipFile(bundle, "a") as archive:
                    warnings.simplefilter("ignore", UserWarning)
                    name = {"extra": "extra", "traversal": "../escape",
                            "duplicate": "full-arm64-v8a.jar", "symlink": "link"}[kind]
                    entry = zipfile.ZipInfo(name)
                    if kind == "symlink":
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, "unsafe")
                with self.assertRaises(ValueError):
                    registry.unpack(bundle, self.root / "rejected", 24, "arm64-v8a", self.client.repo, root=self.root)

    def test_missing_release_is_a_build_request_but_broken_published_release_is_an_error(self):
        with patch.object(self.client, "release", return_value=None):
            self.assertFalse(registry.available(self.client, self.ident))
        with patch.object(self.client, "release", return_value=self.release(draft=True)):
            self.assertFalse(registry.available(self.client, self.ident))
        with patch.object(self.client, "release", return_value=self.release()):
            with self.assertRaisesRegex(ValueError, "missing or unexpected assets"):
                registry.available(self.client, self.ident)

    def test_published_release_requires_all_five_api_abi_assets_and_github_digests(self):
        self.all_bundles()
        release = self.release()
        with patch.object(self.client, "release", return_value=release):
            self.assertTrue(registry.available(self.client, self.ident))
        for field, value in (("digest", None), ("size", 0), ("state", "new")):
            invalid = json.loads(json.dumps(release))
            invalid["assets"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                registry.release_assets(invalid, self.ident)

    def test_download_only_fetches_matching_api_and_verifies_all_before_output(self):
        self.all_bundles()
        with patch.object(self.client, "release", return_value=self.release()), \
             patch.object(self.client, "download", side_effect=self.copy_download) as download:
            output = self.root / "downloaded"
            registry.download(self.client, output, 23, root=self.root)
        self.assertEqual(download.call_count, 2)
        self.assertEqual({path.name for path in output.iterdir()},
                         {"full-arm64-v8a.jar", "full-arm64-v8a.json", "full-armeabi-v7a.jar", "full-armeabi-v7a.json"})
        self.rewrite(self.bundles / registry.bundle_name(23, "arm64-v8a"),
                     record=lambda record: record.update({"api": 24}))
        with patch.object(self.client, "release", return_value=self.release()), \
             patch.object(self.client, "download", side_effect=self.copy_download):
            with self.assertRaises(ValueError):
                registry.download(self.client, self.root / "partial", 23, root=self.root)
        self.assertFalse((self.root / "partial").exists())

    def test_asset_bytes_must_match_both_github_size_and_digest(self):
        self.all_bundles()
        release = self.release()
        asset = release["assets"][0]
        for failure in ("size", "digest"):
            with tempfile.TemporaryDirectory() as temporary, self.subTest(failure=failure):
                temporary = Path(temporary)
                invalid = dict(asset)
                invalid[failure] = 1 if failure == "size" else "sha256:" + "0" * 64
                with patch.object(self.client, "command", side_effect=lambda *args: self.copy_download(release, asset, temporary)):
                    with self.assertRaises(ValueError):
                        self.client.download(release, invalid, temporary)

    def test_missing_dependency_never_falls_back_to_another_version(self):
        with patch.object(self.client, "release", return_value=None), patch.object(self.client, "command") as command:
            with self.assertRaisesRegex(ValueError, "not ready"):
                registry.download(self.client, self.root / "downloaded", 24, root=self.root)
            command.assert_not_called()

    def test_complete_published_version_is_reused_without_upload_or_overwrite(self):
        self.all_bundles()
        with patch.object(self.client, "release", return_value=self.release()), patch.object(self.client, "command") as command:
            registry.publish(self.client, self.root / "nonexistent", root=self.root)
            command.assert_not_called()

    def test_new_version_stays_draft_until_all_bundles_are_verified_and_uploaded(self):
        self.all_bundles()
        with patch.object(self.client, "release", side_effect=[None, None, self.release(draft=True)]), \
             patch.object(self.client, "command") as command:
            registry.publish(self.client, self.bundles, root=self.root)
        calls = [call.args for call in command.call_args_list]
        self.assertEqual([call[1] for call in calls], ["create", "upload", "edit"])
        self.assertIn("--draft", calls[0])
        self.assertIn("--latest=false", calls[0])
        self.assertIn("--prerelease", calls[0])
        self.assertIn("--draft=false", calls[-1])

    def test_existing_draft_can_be_repaired_but_upload_failure_does_not_publish(self):
        self.all_bundles()
        draft = self.release(draft=True)
        with patch.object(self.client, "release", return_value=draft), \
             patch.object(self.client, "command", side_effect=RuntimeError("upload failed")) as command:
            with self.assertRaisesRegex(RuntimeError, "upload failed"):
                registry.publish(self.client, self.bundles, root=self.root)
        self.assertEqual([call.args[1] for call in command.call_args_list], ["upload"])

    def test_publish_and_retry_find_drafts_when_tag_endpoint_returns_404(self):
        self.all_bundles()
        for existing_draft in (False, True):
            with self.subTest(existing_draft=existing_draft):
                draft = self.release(draft=True) if existing_draft else None
                commands = []

                def request(request, timeout):
                    url = request.full_url
                    if "/releases/tags/" in url:
                        # GitHub does not resolve a draft's pending tag here,
                        # even after all assets have been uploaded by gh.
                        raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
                    self.assertIn("/releases?per_page=20&page=1", url)
                    return io.BytesIO(json.dumps([draft] if draft else []).encode())

                def command(*args):
                    nonlocal draft
                    commands.append(args[1])
                    if args[1] == "create":
                        self.assertIsNone(draft, "Retry must reuse the existing draft")
                        draft = dict(self.release(draft=True), assets=[])
                    elif args[1] == "upload":
                        self.assertTrue(draft["draft"])
                        draft["assets"] = self.release()["assets"]
                    elif args[1] == "edit":
                        registry.release_assets(draft, self.ident)
                        self.assertIn("--draft=false", args)
                        draft["draft"] = False

                with patch.object(registry.urllib.request, "urlopen", side_effect=request), \
                     patch.object(self.client, "command", side_effect=command):
                    registry.publish(self.client, self.bundles, root=self.root)
                self.assertEqual(commands, (["upload", "edit"] if existing_draft else ["create", "upload", "edit"]))
                self.assertFalse(draft["draft"])

    def test_draft_lookup_paginates_and_matches_exact_pending_tag(self):
        draft = self.release(draft=True)
        unrelated = dict(draft, tag_name=self.ident["tag"] + "-other")
        responses = [urllib.error.HTTPError("https://api.github.com/test", 404, "Not Found", {}, None),
                     io.BytesIO(json.dumps([unrelated] * 20).encode()),
                     io.BytesIO(json.dumps([unrelated, draft]).encode())]
        with patch.object(registry.urllib.request, "urlopen", side_effect=responses) as request:
            self.assertEqual(self.client.release(self.ident["tag"], include_drafts=True), draft)
        self.assertTrue(request.call_args_list[-1].args[0].full_url.endswith("per_page=20&page=2"))

    def test_failed_draft_listing_is_not_a_request_to_create_another_release(self):
        self.all_bundles()
        responses = [urllib.error.HTTPError("https://api.github.com/test", code, "fixture", {}, None)
                     for code in (404, 404, 403)]
        with patch.object(registry.urllib.request, "urlopen", side_effect=responses), \
             patch.object(self.client, "command") as command:
            with self.assertRaises(urllib.error.HTTPError):
                registry.publish(self.client, self.bundles, root=self.root)
            command.assert_not_called()

    def test_publication_between_probe_and_upload_is_reused_without_overwrite(self):
        self.all_bundles()
        with patch.object(self.client, "release", side_effect=[None, self.release()]), \
             patch.object(self.client, "command") as command:
            registry.publish(self.client, self.bundles, root=self.root)
            command.assert_not_called()

    def test_missing_draft_after_upload_does_not_publish(self):
        self.all_bundles()
        with patch.object(self.client, "release", return_value=None), \
             patch.object(self.client, "command") as command:
            with self.assertRaisesRegex(RuntimeError, "missing after upload"):
                registry.publish(self.client, self.bundles, root=self.root)
        self.assertEqual([call.args[1] for call in command.call_args_list], ["create", "upload"])

    def test_missing_target_prevents_creating_any_release(self):
        self.build_bundle()
        with patch.object(self.client, "release", return_value=None), patch.object(self.client, "command") as command:
            with self.assertRaisesRegex(ValueError, "all five"):
                registry.publish(self.client, self.bundles, root=self.root)
            command.assert_not_called()

    def test_mismatched_uploaded_digest_leaves_new_version_unpublished(self):
        self.all_bundles()
        draft = self.release(draft=True)
        draft["assets"][0]["digest"] = "sha256:" + "f" * 64
        with patch.object(self.client, "release", side_effect=[None, None, draft]), \
             patch.object(self.client, "command") as command:
            with self.assertRaisesRegex(ValueError, "differs from verified local bundle"):
                registry.publish(self.client, self.bundles, root=self.root)
            self.assertEqual([call.args[1] for call in command.call_args_list], ["create", "upload"])

    def test_http_404_is_missing_but_permission_failures_are_not_build_requests(self):
        for status in (404, 403):
            error = urllib.error.HTTPError("https://api.github.com/test", status, "fixture", {}, None)
            with self.subTest(status=status), patch.object(registry.urllib.request, "urlopen", side_effect=error):
                if status == 404:
                    self.assertIsNone(self.client.release(self.ident["tag"]))
                else:
                    with self.assertRaises(urllib.error.HTTPError):
                        self.client.release(self.ident["tag"])


if __name__ == "__main__":
    unittest.main()
