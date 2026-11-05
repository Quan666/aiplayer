"""Native source cache and archive integrity boundaries; no network/compiler needed."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('android_native', ROOT / 'scripts/build_android_native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeSourcesTest(unittest.TestCase):
    def test_android_api_selection_requires_explicit_supported_legacy_target(self):
        self.assertEqual(native.selected_api(None, 24, {}), 24)
        self.assertEqual(native.selected_api(None, 24, {'AIPLAYER_ANDROID_MIN_SDK': '23'}), 23)
        self.assertEqual(native.selected_api(24, 24, {'AIPLAYER_ANDROID_MIN_SDK': '23'}), 24)
        for value in ('22', '25', 'invalid', ''):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, '23 or 24'):
                native.selected_api(None, 24, {'AIPLAYER_ANDROID_MIN_SDK': value})

    def test_native_work_fingerprint_separates_android_api_levels(self):
        lock, recipe = b'same locked sources', b'same recipe'
        api23 = native.build_fingerprint(lock, recipe, 23)
        api24 = native.build_fingerprint(lock, recipe, 24)
        self.assertNotEqual(api23, api24)
        self.assertEqual(api23, native.build_fingerprint(lock, recipe, 23))
        self.assertNotEqual(api23, native.build_fingerprint(b'new lock', recipe, 23))
        self.assertNotEqual(api23, native.build_fingerprint(lock, b'new recipe', 23))

    def test_cached_source_is_hashed_before_reuse(self):
        good = b'locked source bytes'
        source = dict(name='fixture', archive='fixture.tar.gz', url='https://example.invalid/archive',
                      sha256=hashlib.sha256(good).hexdigest())
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            archive = cache / source['archive']
            archive.write_bytes(good)
            with mock.patch.object(native.urllib.request, 'urlopen') as request:
                self.assertEqual(native.download(source, cache), archive)
                request.assert_not_called()
            archive.write_bytes(b'poisoned cache')
            response = io.BytesIO(b'poisoned download')
            response.url = source['url']
            with mock.patch.object(native.urllib.request, 'urlopen', return_value=response):
                with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                    native.download(source, cache)
            self.assertEqual(list(cache.glob('*.part')), [])

    def test_extract_rejects_traversal_and_existing_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'malicious.tar.gz'
            with tarfile.open(archive, 'w:gz') as output:
                entry = tarfile.TarInfo('../escape.c')
                entry.size = 1
                output.addfile(entry, io.BytesIO(b'x'))
            with self.assertRaises(tarfile.FilterError):
                native.extract(archive, root / 'sources')
            self.assertFalse((root / 'escape.c').exists())
            (root / 'sources').mkdir()
            with self.assertRaisesRegex(RuntimeError, 'must be fresh'):
                native.extract(archive, root / 'sources')

    def test_patch_applies_beneath_parent_git_repository_and_fails_on_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            source = root / 'nested/source'
            source.mkdir(parents=True)
            text = source / 'fixture.c'
            text.write_text('before\n')
            patch = root / 'fixture.patch'
            patch.write_text('--- a/fixture.c\n+++ b/fixture.c\n@@ -1 +1 @@\n-before\n+after\n')
            native.apply_compat_patch(source, patch, os.environ.copy())
            self.assertEqual(text.read_text(), 'after\n')
            native.apply_compat_patch(source, patch, os.environ.copy())
            self.assertEqual(text.read_text(), 'after\n')
            text.write_text('unrelated source\n')
            with self.assertRaises(subprocess.CalledProcessError):
                native.apply_compat_patch(source, patch, os.environ.copy())
            self.assertEqual(text.read_text(), 'unrelated source\n')

    def test_version_probe_environment_cannot_inherit_parent_git_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            work = root / 'work'
            source = work / 'sources/ffmpeg'
            source.mkdir(parents=True)
            environment = native.isolated_environment(
                os.environ | {'GIT_DIR': str(root / '.git'), 'GIT_WORK_TREE': str(root)}, work)
            self.assertNotIn('GIT_DIR', environment)
            self.assertNotIn('GIT_WORK_TREE', environment)
            result = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=source,
                                    env=environment, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_all_local_patches_match_source_lock(self):
        lock = json.loads(native.LOCK.read_text())
        for name, expected in lock['patches'].items():
            with self.subTest(patch=name):
                self.assertEqual(native.digest(native.NATIVE / 'patches' / name), expected)
        for source in lock['sources']:
            with self.subTest(source=source['name']):
                self.assertTrue(source['url'].startswith('https://'))
                self.assertRegex(source['sha256'], r'^[0-9a-f]{64}$')
                self.assertNotIn('refs/heads/', source['url'])


if __name__ == '__main__':
    unittest.main()
