#!/usr/bin/env python3
"""Build and package native clients using the locked dependency versions.

Examples:
  python3 scripts/package.py android --flutter /path/to/flutter
  python3 scripts/package.py android --android-abi arm64  # optional smaller APK
  python3 scripts/package.py linux --skip-build
  python3 scripts/package.py windows --windows-installer  # Windows + Inno Setup
  python3 scripts/package.py macos    # run on macOS
  python3 scripts/package.py ios      # unsigned .app + IPA, run on macOS

Flutter's normal build runs pub get against pubspec.lock and refreshes the
release plugin registrants; this script never runs pub upgrade. Builds are
deliberately sequential. Android releases use the project's personal-use debug
certificate; the script never creates, prints or copies signing secrets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "client"
APPLICATION_ID = "app.aiplayer.aiplayer"


def run(command: list[str], *, cwd: Path = ROOT, capture: bool = False) -> str:
    # Windows CreateProcess does not expand PATHEXT like PowerShell does:
    # "flutter" must resolve to flutter.bat before passing it to subprocess.
    # Keep an argument list so paths with spaces are quoted by subprocess.
    executable = shutil.which(command[0])
    if executable is None:
        raise FileNotFoundError(f"Build tool not found: {command[0]}. Install it or provide its full path.")
    resolved = [str(Path(executable).resolve()), *command[1:]]
    result = subprocess.run(resolved, cwd=cwd, check=True, text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout or ""


def write(path: Path, content: str, *, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prune_android_jni(bundle: Path) -> None:
    """Omit path_provider_android's unused desktop JNI helper.

    The generated Dart registrant selects PathProviderLinux on Linux; JNI is
    loaded lazily by Jni._dylib only when Android bindings are called. Its
    desktop .so otherwise embeds the build host's absolute Java RUNPATH.
    Guard this assumption against a future native-assets or ELF dependency.
    """
    helper = bundle / "lib/libdartjni.so"
    if not helper.exists():
        return
    manifest = bundle / "data/flutter_assets/NativeAssetsManifest.json"
    if not manifest.exists() or "jni" in manifest.read_text().lower():
        raise RuntimeError("Review JNI requirements before packaging: native-assets manifest is absent or references JNI")
    for path in [bundle / "aiplayer", *(bundle / "lib").glob("*.so")]:
        if path == helper:
            continue
        dynamic = run(["readelf", "-d", str(path)], capture=True)
        if "libdartjni.so" in dynamic:
            raise RuntimeError(f"Review JNI requirements before packaging: {path.name} links libdartjni.so")
    helper.unlink()


def linux_dependencies(bundle: Path, temporary: Path) -> str:
    """Resolve direct ELF requirements against this build host's dpkg metadata.

    Flutter/plugin libraries are bundled and have no dpkg metadata. Ignore
    those names, but still scan every ELF so their system dependencies and
    actual minimum symbol versions are represented in the package.
    """
    write(temporary / "debian/control", "Source: aiplayer\nSection: video\nPriority: optional\nMaintainer: AIPlayer contributors <noreply@example.invalid>\n\nPackage: aiplayer\nArchitecture: any\nDescription: Personal video library and player\n")
    files = [bundle / "aiplayer"]
    for path in sorted((bundle / "lib").rglob("*")):
        if path.is_file() and path.suffix != ".a":
            with path.open("rb") as source:
                if source.read(4) == b"\x7fELF":
                    files.append(path)
    result = run(
        ["dpkg-shlibdeps", "--ignore-missing-info", "-O", f"-l{bundle / 'lib'}"] + [f"-e{path}" for path in files],
        cwd=temporary,
        capture=True,
    )
    for line in result.splitlines():
        if line.startswith("shlibs:Depends="):
            # GIO loads the desktop/PAC proxy backend dynamically, so ELF
            # dependency scanning alone cannot discover this requirement.
            return line.removeprefix("shlibs:Depends=") + ", glib-networking"
    raise RuntimeError("dpkg-shlibdeps did not return dependencies")


def linux_package(output: Path, version: str) -> tuple[list[Path], dict]:
    machine = platform.machine()
    arch, deb_arch = {"x86_64": ("x64", "amd64"), "aarch64": ("arm64", "arm64")}[machine]
    bundle = CLIENT / "build/linux" / arch / "release/bundle"
    if not (bundle / "aiplayer").is_file():
        raise RuntimeError(f"No Linux release bundle: {bundle}")
    dependencies = None
    artifacts = []
    with tempfile.TemporaryDirectory(prefix="aiplayer-package-") as directory:
        temporary = Path(directory)
        stage = temporary / f"aiplayer-linux-{arch}"
        shutil.copytree(bundle, stage)
        for archive in (stage / "lib").glob("*.a"):
            archive.unlink()  # Build-only static archives are not runtime assets.
        prune_android_jni(stage)
        icon = CLIENT / "linux/runner/resources/app_icon.png"
        shutil.copy2(icon, stage / "data/app_icon.png")
        write(stage / "launch.sh", '#!/bin/sh\nset -eu\naiplayer_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$aiplayer_dir/aiplayer" "$@"\n', executable=True)
        shutil.copy2(CLIENT / f"linux/runner/resources/{APPLICATION_ID}.desktop", stage / f"{APPLICATION_ID}.desktop")
        if shutil.which("dpkg-deb") and shutil.which("dpkg-shlibdeps"):
            dependencies = linux_dependencies(stage, temporary)
        write(stage / "RUNTIME.txt", f"映库 {version} / Linux {arch}\n\nLaunch: ./launch.sh\nBuild host: {platform.platform()}\nSystem packages: {dependencies or 'GTK 3, libmpv 2, libsecret 1, glib-networking and a compatible glibc/libstdc++'}\nCredentials require a running Secret Service (for example GNOME Keyring).\nSystem proxy and PAC settings require a GIO desktop proxy backend (glib-networking).\nThis bundle includes Flutter and application plugins; system libraries are not bundled.\n")
        archive = output / f"aiplayer-linux-{arch}.tar.gz"
        with tarfile.open(archive, "w:gz") as target:
            target.add(stage, arcname=stage.name)
        artifacts.append(archive)
        if dependencies:
            debroot = temporary / "deb"
            shutil.copytree(stage, debroot / "opt/aiplayer")
            write(debroot / "usr/bin/aiplayer", '#!/bin/sh\nexec /opt/aiplayer/launch.sh "$@"\n', executable=True)
            appdir = debroot / "usr/share/applications"
            appdir.mkdir(parents=True)
            shutil.copy2(stage / f"{APPLICATION_ID}.desktop", appdir)
            icons = debroot / "usr/share/icons/hicolor/512x512/apps"
            icons.mkdir(parents=True)
            shutil.copy2(icon, icons / f"{APPLICATION_ID}.png")
            installed_kib = (sum(path.stat().st_size for path in debroot.rglob("*") if path.is_file()) + 1023) // 1024
            deb_version = version.replace("+", "-")
            write(debroot / "DEBIAN/control", f"Package: aiplayer\nVersion: {deb_version}\nSection: video\nPriority: optional\nArchitecture: {deb_arch}\nMaintainer: AIPlayer contributors <noreply@example.invalid>\nInstalled-Size: {installed_kib}\nDepends: {dependencies}\nRecommends: gnome-keyring\nDescription: Personal video library and player\n Local, SMB, WebDAV and HTTP playback, subtitles and danmaku.\n")
            deb = output / f"aiplayer-linux-{deb_arch}.deb"
            run(["dpkg-deb", "--root-owner-group", "--build", str(debroot), str(deb)])
            artifacts.append(deb)
    return artifacts, {"architecture": arch, "runtime_dependencies": dependencies}


def android_package(output: Path, abi: str, version: str, *, keep_alias: bool = True) -> tuple[list[Path], dict]:
    from validate_apk import validate_apk

    source = CLIENT / "build/app/outputs/flutter-apk" / ("app-arm64-v8a-release.apk" if abi == "arm64" else "app-release.apk")
    if not source.is_file():
        raise RuntimeError(f"No Android release APK: {source}")
    validation = validate_apk(source, abi=abi, expected_version=version)
    expected_certificate = (ROOT / "signing/android-certificate.sha256").read_text().strip()
    if validation["certificate_sha256"] != expected_certificate:
        raise RuntimeError(
            "APK signing certificate changed; refusing to package an incompatible update. "
            f"Expected SHA-256: {expected_certificate}; "
            f"APK certificate SHA-256: {validation['certificate_sha256']}"
        )
    abis = validation["abis"]
    artifacts = []
    if keep_alias:
        target = output / ("aiplayer-android-arm64-release.apk" if abi == "arm64" else "aiplayer-android-release.apk")
        shutil.copy2(source, target)
        artifacts.append(target)
    version_name = re.sub(r"[^0-9A-Za-z._-]", "_", validation["version_name"])
    versioned = output / f"aiplayer-{version_name}-android{'-arm64' if abi == 'arm64' else ''}.apk"
    shutil.copy2(source, versioned)
    artifacts.append(versioned)
    return artifacts, {"architecture": "arm64-v8a" if abi == "arm64" else "universal", "abis": abis, "minimum_android": "7.0 (API 24)", "signing": "v1 + v2 + v3, existing local debug certificate (personal-use release)", "apk_validation": validation}


def windows_package(output: Path, version: str, *, installer: bool = False) -> tuple[list[Path], dict]:
    source = CLIENT / "build/windows/x64/runner/Release"
    if not (source / "aiplayer.exe").is_file():
        raise RuntimeError(f"No Windows release bundle: {source}")
    runtimes = ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"]
    if any(not (source / name).is_file() for name in runtimes):
        raise RuntimeError("Windows bundle is missing Visual C++ runtime DLLs; rebuild with the current CMake configuration")
    # Include the optional association helper in both the ZIP and installer.
    shutil.copy2(CLIENT / "windows/register-open-with.ps1", source)
    shutil.copy2(ROOT / "docs/DESKTOP_OPEN_WITH.md", source)
    target = output / "aiplayer-windows-x64.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in source.rglob("*"):
            if path.is_file():
                archive.write(path, path.relative_to(source))
    artifacts = [target]
    if installer:
        compiler = os.environ.get("AIPLAYER_ISCC") or shutil.which("ISCC.exe")
        if not compiler:
            raise RuntimeError("Install Inno Setup 6 and set AIPLAYER_ISCC to ISCC.exe")
        name, _, build = version.partition("+")
        file_version = f"{name.split('-')[0]}.{build or '0'}"
        run([compiler, f"/DAppVersion={version}", f"/DFileVersion={file_version}", f"/DSourceDir={source}",
             f"/DOutputDir={output}", f"/DAppIcon={CLIENT / 'windows/runner/resources/app_icon.ico'}",
             str(ROOT / "scripts/windows/installer.iss")])
        setup = output / "aiplayer-windows-x64-setup.exe"
        if not setup.is_file():
            raise RuntimeError("Inno Setup did not produce the expected installer")
        artifacts.append(setup)
    return artifacts, {"architecture": "x64", "signing": "unsigned", "bundled_vc_runtime": runtimes}


def apple_package(output: Path, target: str) -> tuple[list[Path], dict]:
    products = CLIENT / ("build/macos/Build/Products/Release" if target == "macos" else "build/ios/iphoneos")
    apps = list(products.glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError(f"Expected one .app in {products}, found {len(apps)}")
    archive = output / f"aiplayer-{target}-unsigned.zip"
    # ditto preserves bundle symlinks and resource metadata.
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(apps[0]), str(archive)])
    artifacts = [archive]
    details = {"signing": "not notarized" if target == "macos" else "unsigned .app; sign on a Mac before installing on a device"}
    if target == "macos":
        # A drag-to-Applications image; ditto preserves framework symlinks.
        with tempfile.TemporaryDirectory(prefix="aiplayer-dmg-") as directory:
            stage = Path(directory) / "AIPlayer"
            stage.mkdir()
            run(["ditto", str(apps[0]), str(stage / apps[0].name)])
            (stage / "Applications").symlink_to("/Applications")
            dmg = output / "aiplayer-macos-unsigned.dmg"
            run(["hdiutil", "create", "-volname", "AIPlayer", "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(dmg)])
            run(["hdiutil", "verify", str(dmg)])
            artifacts.append(dmg)
        details["architectures"] = run(["lipo", "-archs", str(apps[0] / "Contents/MacOS/aiplayer")], capture=True).strip().split()
    else:
        # An IPA is a ZIP with Payload/<app>.app. It still requires the user's
        # signing certificate and provisioning profile before device installation.
        with tempfile.TemporaryDirectory(prefix="aiplayer-ipa-") as directory:
            payload = Path(directory) / "Payload"
            payload.mkdir()
            run(["ditto", str(apps[0]), str(payload / apps[0].name)])
            ipa = output / "aiplayer-ios-unsigned.ipa"
            run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(ipa)])
            with zipfile.ZipFile(ipa) as bundle:
                if f"Payload/{apps[0].name}/Info.plist" not in bundle.namelist() or bundle.testzip():
                    raise RuntimeError("Invalid unsigned IPA layout or CRC")
            artifacts.append(ipa)
        details["signing"] = "unsigned .app and IPA; re-sign with a valid certificate and provisioning profile before installing"
    return artifacts, details


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("target", choices=["android", "linux", "windows", "macos", "ios"])
    parser.add_argument("--skip-build", action="store_true", help="Package an existing release build")
    parser.add_argument("--verbose", action="store_true", help="Show full Flutter build output, including native build and installation diagnostics")
    parser.add_argument("--flutter", default=os.environ.get("AIPLAYER_FLUTTER", "flutter"))
    parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--android-abi", choices=["universal", "arm64"], default="universal", help="Default Android APK runs on ARM32, ARM64 and x86_64; arm64 produces an optional smaller APK")
    parser.add_argument("--no-android-alias", action="store_true", help="Only produce the versioned APK, without a duplicate fixed-name alias (Android only)")
    parser.add_argument("--windows-installer", action="store_true", help="Also build an unsigned Windows EXE installer using Inno Setup 6")
    arguments = parser.parse_args()
    if arguments.windows_installer and arguments.target != "windows":
        parser.error("--windows-installer requires the windows target")
    if arguments.no_android_alias and arguments.target != "android":
        parser.error("--no-android-alias requires the android target")
    supported_host = {"linux": "Linux", "windows": "Windows", "macos": "Darwin", "ios": "Darwin"}
    expected = supported_host.get(arguments.target)
    if expected and platform.system() != expected:
        parser.error(f"{arguments.target} requires a {expected} build host")
    version_match = re.search(r"^version:\s*(\S+)", (CLIENT / "pubspec.yaml").read_text(), re.MULTILINE)
    if not version_match:
        raise RuntimeError("Missing pubspec version")
    version = version_match.group(1)
    if not arguments.skip_build:
        # Let Flutter refresh registrants for release. --no-pub can retain
        # integration_test's generated registration after an integration run.
        command = [arguments.flutter]
        if arguments.verbose:
            command.append("--verbose")
        command += ["build", "apk" if arguments.target == "android" else arguments.target, "--release"]
        if arguments.target == "android":
            command += ["--target-platform", "android-arm64" if arguments.android_abi == "arm64" else "android-arm,android-arm64,android-x64"]
            if arguments.android_abi == "arm64":
                # Personal-use APK variants share the pubspec build number so
                # users can switch between universal and ARM64 installations.
                command += ["--split-per-abi", "--android-project-arg=force-version-code-ignoring-abi=true"]
        elif arguments.target == "ios":
            command += ["--no-codesign"]
        run(command, cwd=CLIENT)
    output = arguments.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if arguments.target == "android":
        artifacts, details = android_package(output, arguments.android_abi, version, keep_alias=not arguments.no_android_alias)
    elif arguments.target == "linux":
        artifacts, details = linux_package(output, version)
    elif arguments.target == "windows":
        artifacts, details = windows_package(output, version, installer=arguments.windows_installer)
    else:
        artifacts, details = apple_package(output, arguments.target)
    checksums = []
    artifact_details = []
    for path in artifacts:
        checksum = sha256(path)
        checksums.append(f"{checksum}  {path.name}\n")
        artifact_details.append({"name": path.name, "size_bytes": path.stat().st_size, "sha256": checksum})
        print(f"Packaged {path} ({path.stat().st_size:,} bytes)")
    metadata_target = "android-arm64" if arguments.target == "android" and arguments.android_abi == "arm64" else arguments.target
    write(output / f"SHA256SUMS-{metadata_target}", "".join(checksums))
    write(output / f"build-{metadata_target}.json", json.dumps({"version": version, "target": arguments.target, "mode": "release", "host": platform.platform(), "artifacts": [path.name for path in artifacts], "artifact_details": artifact_details, **details}, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
