import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "prepare_android_legacy.py"
spec = importlib.util.spec_from_file_location("prepare_legacy", SCRIPT)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


class PrepareLegacyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        self.output = self.root / ".local-build/legacy"
        fixtures = {
            "client/pubspec.yaml": "environment:\n  sdk: '>=3.13.0 <4.0.0'\ndependencies:\n  qr: 4.0.1\n",
            "client/pubspec.lock": "main-lock\n",
            "client/android/app/build.gradle.kts": "minSdk = 24\ncompileSdk = flutter.compileSdkVersion\ntargetSdk = flutter.targetSdkVersion\nndkVersion = flutter.ndkVersion\n",
            "client/android/settings.gradle.kts": 'pluginManagement {\n}\nplugins {\n    id("com.android.application") version "9.1.0"\n    id("org.jetbrains.kotlin.android") version "2.4.21"\n}\n',
            "client/android/gradle.properties": "android.useAndroidX=true\n",
            "client/android/gradle/wrapper/gradle-wrapper.properties": "distributionUrl=old\ndistributionSha256Sum=old\n",
            "packages/aiplayer_smb/pubspec.yaml": "sdk: '>=3.9.0 <4.0.0'\n",
            "packages/aiplayer_smb/android/build.gradle": "defaultConfig { minSdk 24 }\n",
            "client/build/generated": "must not copy\n",
            "client/android/local.properties": "must not copy\n",
            "scripts/package.py": "# fixture\n",
            "signing/android-certificate.sha256": "certificate\n",
            "compat/android6/pubspec.lock": "legacy-lock\n",
            "compat/android6/verification-metadata.xml": "legacy-metadata\n",
            "compat/android6/adapt_sources.py": "def adapt_sources(root):\n    return ['fixture']\n",
            "compat/android6/toolchain.json": (legacy.ROOT / "compat/android6/toolchain.json").read_text(),
        }
        for name, text in fixtures.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def test_snapshot_is_isolated_and_uses_reviewed_locks(self):
        original = (self.root / "client/pubspec.yaml").read_text()
        legacy.prepare(self.output, root=self.root)
        self.assertEqual((self.root / "client/pubspec.yaml").read_text(), original)
        self.assertIn(">=3.8.1 <3.9.0", (self.output / "client/pubspec.yaml").read_text())
        self.assertIn('abiFilters += setOf("armeabi-v7a", "arm64-v8a")',
                      (self.output / "client/android/app/build.gradle.kts").read_text())
        self.assertEqual((self.output / "client/pubspec.lock").read_text(), "legacy-lock\n")
        self.assertEqual((self.output / "client/android/gradle/verification-metadata.xml").read_text(), "legacy-metadata\n")
        self.assertFalse((self.output / "client/build").exists())
        self.assertFalse((self.output / "client/android/local.properties").exists())
        stale = self.output / "client/stale.dart"
        stale.write_text("old source")
        legacy.prepare(self.output, root=self.root)
        self.assertFalse(stale.exists())
        self.assertEqual(json.loads((self.output / legacy.MARKER).read_text())["min_sdk"], 23)

    def test_r8_override_is_in_parent_classloader_and_preserves_kotlin(self):
        original = (self.root / "client/android/settings.gradle.kts").read_text()
        legacy.prepare(self.output, root=self.root)
        settings = (self.output / "client/android/settings.gradle.kts").read_text()
        tools = json.loads((self.root / "compat/android6/toolchain.json").read_text())
        self.assertEqual((self.root / "client/android/settings.gradle.kts").read_text(), original)
        self.assertIn('id("org.jetbrains.kotlin.android") version "2.4.21"', settings)
        self.assertIn('id("com.android.application") version "8.13.0"', settings)
        plugin_management = settings.split("plugins {", 1)[0]
        self.assertIn("    buildscript {", plugin_management)
        self.assertIn(f'classpath("com.android.tools:r8:{tools["r8"]}")', plugin_management)
        self.assertIn("google()", plugin_management)
        self.assertNotIn("languageVersion", settings)
        self.assertNotIn("apiVersion", settings)

    def test_old_unpinned_or_malformed_r8_is_rejected_without_mutating_settings(self):
        settings = self.root / "client/android/settings.gradle.kts"
        original = settings.read_text()
        for version in ("8.13.6", "9.1.28", "9.1.+", "latest.release", '9.1.31")'):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "pinned R8"):
                legacy.override_r8(settings, version)
            self.assertEqual(settings.read_text(), original)

    def test_r8_override_fails_if_plugin_management_anchor_changes(self):
        settings = self.root / "client/android/settings.gradle.kts"
        settings.write_text("plugins { }\n")
        with self.assertRaisesRegex(RuntimeError, "Compatibility anchor changed"):
            legacy.override_r8(settings, "9.1.31")
        self.assertEqual(settings.read_text(), "plugins { }\n")

    def test_refuses_source_and_unrelated_directory(self):
        for target in (self.root, self.root.parent, self.root / "client/snapshot"):
            with self.assertRaises(ValueError):
                legacy.prepare(target, root=self.root)
        self.output.mkdir(parents=True)
        sentinel = self.output / "keep"
        sentinel.write_text("important")
        with self.assertRaises(ValueError):
            legacy.prepare(self.output, root=self.root)
        self.assertEqual(sentinel.read_text(), "important")

    def test_missing_locks_do_not_destroy_previous_snapshot(self):
        legacy.prepare(self.output, root=self.root)
        (self.root / "compat/android6/pubspec.lock").unlink()
        with self.assertRaises(RuntimeError):
            legacy.prepare(self.output, root=self.root)
        self.assertTrue((self.output / "client/pubspec.yaml").exists())


if __name__ == "__main__":
    unittest.main()
