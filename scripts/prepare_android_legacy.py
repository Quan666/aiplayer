#!/usr/bin/env python3
"""Create an isolated Android 6 source snapshot; never downgrade the main client.

The snapshot contains current application sources plus reviewed compatibility
adaptations and its own dependency locks. Re-run this before each legacy build.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
MARKER = ".aiplayer-android6-snapshot.json"
SOURCE_DIRECTORIES = ("client", "packages", "scripts", "signing", "compat")


def replace(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"Compatibility anchor changed in {path}: {old!r}")
    path.write_text(text.replace(old, new))


def override_r8(settings: Path, version: str) -> None:
    # R8 is embedded in AGP's builder.jar. Put the maintained version in the
    # parent plugin classloader, as prescribed by the official R8 README:
    # https://r8.googlesource.com/r8/+/refs/heads/main/README.md#replacing-r8-in-android-gradle-plugin
    # This preserves Kotlin 2.4 metadata and AGP 8's Flutter integration.
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or tuple(map(int, version.split("."))) < (9, 1, 29):
        raise ValueError("Android 6 builds with Kotlin 2.4 require a pinned R8 version >= 9.1.29")
    replace(settings, "pluginManagement {", (
        "pluginManagement {\n"
        "    // Keep Kotlin 2.4 support while retaining the legacy Flutter/AGP bridge.\n"
        "    buildscript {\n"
        "        repositories {\n"
        "            google()\n"
        "            mavenCentral()\n"
        "        }\n"
        "        dependencies {\n"
        f'            classpath("com.android.tools:r8:{version}")\n'
        "        }\n"
        "    }\n"
    ))


def prepare(output: Path, *, root: Path = ROOT, bootstrap: bool = False) -> Path:
    root, output = root.resolve(), output.resolve()
    if output == root or root.is_relative_to(output) or any(
        output.is_relative_to(root / name) for name in SOURCE_DIRECTORIES
    ):
        raise ValueError("The legacy snapshot must be outside the source directories")
    config = root / "compat/android6"
    lock = config / "pubspec.lock"
    metadata = config / "verification-metadata.xml"
    if not bootstrap and (not lock.is_file() or not metadata.is_file()):
        raise RuntimeError("Android 6 dependency locks are missing; resolve and review them first")
    marker = output / MARKER
    if output.exists() and any(output.iterdir()):
        if not marker.is_file() or json.loads(marker.read_text()).get("source") != str(root):
            raise ValueError(f"Refusing to replace an unrelated directory: {output}")
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    marker.write_text(json.dumps({"source": str(root), "profile": "android6"}) + "\n")
    ignore = shutil.ignore_patterns(
        ".git", ".dart_tool", ".gradle", ".cxx", "build", "ephemeral",
        "__pycache__", "*.pyc", "local.properties", ".flutter-plugins",
        ".flutter-plugins-dependencies", "Pods", "node_modules",
    )
    for name in SOURCE_DIRECTORIES:
        shutil.copytree(root / name, output / name, ignore=ignore)
    tools = json.loads((config / "toolchain.json").read_text())
    replace(output / "client/pubspec.yaml", ">=3.13.0 <4.0.0", ">=3.8.1 <3.9.0")
    replace(output / "client/pubspec.yaml", "  qr: 4.0.1", "  qr: 3.0.3")
    replace(output / "packages/aiplayer_smb/pubspec.yaml", ">=3.9.0 <4.0.0", ">=3.8.1 <4.0.0")
    replace(output / "packages/aiplayer_smb/android/build.gradle", "minSdk 24", "minSdk 23")
    app = output / "client/android/app/build.gradle.kts"
    replace(app, "minSdk = 24", 'minSdk = 23\n        ndk { abiFilters += setOf("armeabi-v7a", "arm64-v8a") }')
    replace(app, "compileSdk = flutter.compileSdkVersion", f"compileSdk = {tools['compile_sdk']}")
    replace(app, "targetSdk = flutter.targetSdkVersion", f"targetSdk = {tools['compile_sdk']}")
    replace(app, "ndkVersion = flutter.ndkVersion", f'ndkVersion = "{tools["ndk"]}"')
    settings = output / "client/android/settings.gradle.kts"
    replace(settings, 'id("com.android.application") version "9.1.0"',
            f'id("com.android.application") version "{tools["android_gradle_plugin"]}"')
    override_r8(settings, tools["r8"])
    wrapper = output / "client/android/gradle/wrapper/gradle-wrapper.properties"
    text = re.sub(r"(?m)^distributionUrl=.*$", lambda _: (
        f'distributionUrl=https\\://services.gradle.org/distributions/gradle-{tools["gradle"]}-bin.zip'
    ), wrapper.read_text())
    text = re.sub(r"(?m)^distributionSha256Sum=.*$",
                  f'distributionSha256Sum={tools["gradle_bin_sha256"]}', text)
    wrapper.write_text(text)
    properties = output / "client/android/gradle.properties"
    properties.write_text(properties.read_text() + (
        "\n# Match the maintained Kotlin metadata reader without upgrading the legacy AGP.\n"
        f'android.experimental.lint.version={tools["android_lint"]}\n'
    ))
    target_lock = output / "client/pubspec.lock"
    if lock.is_file():
        shutil.copy2(lock, target_lock)
    else:
        target_lock.unlink(missing_ok=True)
    if metadata.is_file():
        shutil.copy2(metadata, output / "client/android/gradle/verification-metadata.xml")
    spec = importlib.util.spec_from_file_location("android6_adapt", config / "adapt_sources.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    adaptations = module.adapt_sources(output)
    marker.write_text(json.dumps({
        "source": str(root), "profile": "android6", "flutter": tools["flutter"],
        "min_sdk": tools["min_sdk"], "adapted_sources": adaptations,
    }, indent=2) + "\n")
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".local-build/android6/source")
    parser.add_argument("--bootstrap", action="store_true",
                        help="Maintainers only: prepare before resolving/reviewing legacy locks")
    args = parser.parse_args()
    print(prepare(args.output, bootstrap=args.bootstrap))


if __name__ == "__main__":
    main()
