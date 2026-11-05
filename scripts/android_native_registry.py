#!/usr/bin/env python3
"""Publish and consume Android player dependencies identified by their inputs.

Only the native workflow compiles these libraries. Application packaging reads
an exact dependency release and verifies both GitHub asset digests and the
embedded source/API/ABI metadata. Published dependency releases are never
overwritten. The registry is the same repository as the consuming workflow.
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
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

from verify_android_native import digest, verify

ROOT = Path(__file__).resolve().parents[1]
NATIVE = "packages/media_kit_libs_android_video/native"
MANIFEST = "native-bundle.json"
MAX_ASSET_SIZE = 128 * 1024 * 1024
TARGETS = ((24, "armeabi-v7a"), (24, "arm64-v8a"), (24, "x86_64"),
           (23, "armeabi-v7a"), (23, "arm64-v8a"))


def identity(root: Path = ROOT) -> dict:
    tools = json.loads((root / NATIVE / "toolchain.json").read_text())
    lock = json.loads((root / NATIVE / "sources.lock.json").read_text())
    if tools.get("schema") != 1 or sorted((t["api"], t["abi"]) for t in tools["targets"]) != sorted(TARGETS):
        raise ValueError("Native toolchain must declare exactly the five supported API/ABI targets")
    if not 1 <= tools["max_jobs"] <= 16:
        raise ValueError("Native compiler concurrency must be between 1 and 16")
    inputs = [f"{NATIVE}/sources.lock.json", f"{NATIVE}/toolchain.json",
              "scripts/build_android_native.py", "scripts/verify_android_native.py",
              "scripts/android_native_registry.py", ".github/workflows/android-native.yml"]
    for name, expected in lock["patches"].items():
        if Path(name).name != name or digest(root / NATIVE / "patches" / name) != expected:
            raise ValueError(f"Native patch hash mismatch or unsafe name: {name}")
        inputs.append(f"{NATIVE}/patches/{name}")
    hashes = {}
    for name in sorted(inputs):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Native input must be a regular file: {name}")
        hashes[name] = digest(path)
    fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return dict(fingerprint=fingerprint, tag=f"native-android-{fingerprint}", inputs=hashes,
                targets=tools["targets"], runner=tools["runner"], ndk=lock["ndk"])


def bundle_name(api: int, abi: str) -> str:
    if (api, abi) not in TARGETS:
        raise ValueError("Unsupported native registry target")
    return f"android-api{api}-{abi}.zip"


def bundle_files(abi: str) -> set[str]:
    return {f"full-{abi}.jar", f"full-{abi}.json"}


def pack(directory: Path, output: Path, api: int, abi: str, *, root: Path = ROOT) -> Path:
    ident = identity(root)
    bundle_name(api, abi)  # Validate before constructing filesystem paths.
    verify(directory, abi, api, root=root)
    commit = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Native bundles require the producer's exact Git commit")
    record = dict(schema=1, fingerprint=ident["fingerprint"], inputs=ident["inputs"],
                  api=api, abi=abi, source_commit=commit,
                  repository=os.environ["GITHUB_REPOSITORY"],
                  run_id=os.environ["GITHUB_RUN_ID"],
                  environment=dict(runner=ident["runner"], image_version=os.environ.get("ImageVersion", ""),
                                   python=platform.python_version(), ndk=ident["ndk"]),
                  files={name: digest(directory / name) for name in sorted(bundle_files(abi))})
    output.mkdir(parents=True, exist_ok=True)
    target = output / bundle_name(api, abi)
    # JARs are already compressed; avoid recompressing large ELF payloads.
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr(MANIFEST, json.dumps(record, sort_keys=True, indent=2) + "\n")
        for name in sorted(bundle_files(abi)):
            archive.write(directory / name, name)
    return target


def unpack(bundle: Path, output: Path, api: int, abi: str, repo: str, *, root: Path = ROOT) -> None:
    ident = identity(root)
    expected_files = bundle_files(abi)
    bundle_name(api, abi)
    if bundle.is_symlink() or bundle.stat().st_size > MAX_ASSET_SIZE:
        raise ValueError("Native bundle is a symlink or exceeds size limits")
    with tempfile.TemporaryDirectory(prefix="aiplayer-native-verify-") as temporary:
        temporary = Path(temporary)
        with zipfile.ZipFile(bundle) as archive:
            entries = archive.infolist()
            if len(entries) != 3 or {e.filename for e in entries} != expected_files | {MANIFEST}:
                raise ValueError("Native bundle has missing, duplicate or unexpected paths")
            for entry in entries:
                if stat.S_ISLNK(entry.external_attr >> 16) or entry.file_size > MAX_ASSET_SIZE:
                    raise ValueError("Native bundle contains a symlink or oversized file")
            if sum(e.file_size for e in entries) > MAX_ASSET_SIZE or archive.getinfo(MANIFEST).file_size > 65536:
                raise ValueError("Native bundle expands beyond size limits")
            record = json.loads(archive.read(MANIFEST))
            expected = dict(schema=1, fingerprint=ident["fingerprint"], inputs=ident["inputs"],
                            api=api, abi=abi, repository=repo)
            if not isinstance(record, dict) or any(record.get(k) != v for k, v in expected.items()):
                raise ValueError("Native bundle source, toolchain, repository, API or ABI changed")
            if not re.fullmatch(r"[0-9a-f]{40}", str(record.get("source_commit", ""))):
                raise ValueError("Native bundle has no exact source commit")
            if not re.fullmatch(r"[0-9]+", str(record.get("run_id", ""))):
                raise ValueError("Native bundle has no producer run identity")
            if set(record.get("files", {})) != expected_files:
                raise ValueError("Native bundle checksum list is incomplete")
            for name in expected_files:
                # Names are a fixed allowlist; never extract arbitrary ZIP paths.
                with archive.open(name) as source, (temporary / name).open("wb") as target:
                    shutil.copyfileobj(source, target)
                if digest(temporary / name) != record["files"][name]:
                    raise ValueError(f"Native bundle checksum mismatch: {name}")
        verify(temporary, abi, api, root=root)
        output.mkdir(parents=True, exist_ok=True)
        if output.is_symlink() or any((output / name).exists() or (output / name).is_symlink() for name in expected_files):
            raise ValueError("Refusing to overwrite native inputs")
        for name in expected_files:
            shutil.copyfile(temporary / name, output / name)


class Registry:
    def __init__(self, repo: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("Invalid native registry repository")
        self.repo = repo

    def release(self, tag: str, *, include_drafts: bool = False) -> dict | None:
        release = self._get(f"releases/tags/{tag}")
        if release is not None or not include_drafts:
            return release
        # The tag endpoint only finds published releases. Drafts have a pending
        # tag (and an untagged-* URL), so publishers must search the authenticated
        # release listing. Paginate to find drafts left by older failed runs.
        page = 1
        while True:
            releases = self._get(f"releases?per_page=20&page={page}")
            if not isinstance(releases, list):
                raise ValueError("Cannot list native dependency drafts")
            for release in releases:
                if release.get("tag_name") == tag:
                    return release
            if len(releases) < 20:
                return None
            page += 1

    def _get(self, path: str) -> dict | list | None:
        url = f"https://api.github.com/repos/{self.repo}/{path}"
        headers = {"Accept": "application/vnd.github+json", "User-Agent": "AIPlayer-native-registry"}
        token = os.environ.get("GH_TOKEN")
        if token:
            headers["Authorization"] = f"Bearer {token}"
        for attempt in range(3):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
                    data = response.read(1024 * 1024 + 1)
                    if len(data) > 1024 * 1024:
                        raise ValueError("Native release metadata exceeds size limits")
                    return json.loads(data)
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return None
                if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                    raise
            except (urllib.error.URLError, TimeoutError):
                if attempt == 2:
                    raise
            time.sleep(2 ** attempt)
        raise RuntimeError("Cannot read native registry")

    def command(self, *args: str) -> None:
        subprocess.run(["gh", *args, "--repo", self.repo], check=True, timeout=300)

    def download(self, release: dict, asset: dict, destination: Path) -> Path:
        self.command("release", "download", release["tag_name"], "--pattern", asset["name"], "--dir", str(destination))
        path = destination / asset["name"]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != asset["size"]:
            raise ValueError("Native asset size changed during download")
        if f"sha256:{digest(path)}" != asset["digest"]:
            raise ValueError("Native asset differs from GitHub's SHA-256 digest")
        return path


def release_assets(release: dict | None, ident: dict) -> dict:
    if not isinstance(release, dict) or release.get("tag_name") != ident["tag"] or not release.get("prerelease"):
        raise ValueError("Unexpected native dependency release")
    expected = {bundle_name(**target) for target in ident["targets"]}
    assets = release.get("assets", [])
    if len(assets) != len(expected) or {a["name"] for a in assets} != expected:
        raise ValueError("Published native release has missing or unexpected assets")
    for asset in assets:
        if (asset.get("state") != "uploaded" or not 0 < asset.get("size", 0) <= MAX_ASSET_SIZE
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", str(asset.get("digest", "")))):
            raise ValueError("Native release asset lacks a complete upload and SHA-256 digest")
    return {asset["name"]: asset for asset in assets}


def available(registry: Registry, ident: dict) -> bool:
    release = registry.release(ident["tag"])
    if release is None or release.get("draft"):
        return False
    release_assets(release, ident)
    return True


def download(registry: Registry, output: Path, api: int, *, root: Path = ROOT) -> None:
    ident = identity(root)
    release = registry.release(ident["tag"])
    if release is None or release.get("draft"):
        raise ValueError(f"Native dependency {ident['tag']} is not ready; run Build Android native")
    assets = release_assets(release, ident)
    with tempfile.TemporaryDirectory(prefix="aiplayer-native-download-") as temporary:
        temporary = Path(temporary)
        staged = temporary / "verified"
        for target in ident["targets"]:
            if target["api"] == api:
                asset = assets[bundle_name(**target)]
                bundle = registry.download(release, asset, temporary)
                unpack(bundle, staged, **target, repo=registry.repo, root=root)
        # Publish only after every ABI for this API has passed validation.
        if output.exists():
            raise ValueError("Native download destination must be new")
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(staged, output)
    print(f"Verified native dependency {ident['tag']} (API {api})")


def publish(registry: Registry, directory: Path, *, root: Path = ROOT) -> None:
    ident = identity(root)
    if available(registry, ident):
        print(f"Reusing published native dependency {ident['tag']}")
        return
    expected = {bundle_name(**target) for target in ident["targets"]}
    if {p.name for p in directory.iterdir()} != expected:
        raise ValueError("Native publication requires exactly all five target bundles")
    with tempfile.TemporaryDirectory(prefix="aiplayer-native-publish-") as temporary:
        temporary = Path(temporary)
        for target in ident["targets"]:
            unpack(directory / bundle_name(**target), temporary / str(target["api"]),
                   **target, repo=registry.repo, root=root)
    release = registry.release(ident["tag"], include_drafts=True)
    # Recheck after local validation: a newly published fingerprint must never
    # be overwritten, even if the initial availability check missed it.
    if release is not None and not release.get("draft"):
        release_assets(release, ident)
        print(f"Reusing published native dependency {ident['tag']}")
        return
    if release is None:
        registry.command("release", "create", ident["tag"], "--draft", "--prerelease", "--latest=false",
                         "--target", os.environ["GITHUB_SHA"], "--title", f"Android native {ident['fingerprint'][:12]}",
                         "--notes", "构建依赖，供 CI 复用；应用安装包请下载 v 开头的正式版本。")
    # Only drafts can be repaired. A published fingerprint is never overwritten.
    registry.command("release", "upload", ident["tag"], *(str(directory / name) for name in sorted(expected)), "--clobber")
    release = registry.release(ident["tag"], include_drafts=True)
    if release is None:
        raise RuntimeError(f"Native dependency draft {ident['tag']} is missing after upload; refusing to publish")
    uploaded = release_assets(release, ident)
    for name, asset in uploaded.items():
        if asset["digest"] != f"sha256:{digest(directory / name)}" or asset["size"] != (directory / name).stat().st_size:
            raise ValueError(f"Uploaded native asset differs from verified local bundle: {name}")
    registry.command("release", "edit", ident["tag"], "--draft=false", "--prerelease", "--latest=false")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("identity", "probe", "pack", "download", "publish", "install-tools"))
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--api", type=int, choices=(23, 24))
    parser.add_argument("--abi")
    parser.add_argument("--fingerprint", default="")
    args = parser.parse_args()
    ident = identity()
    if args.fingerprint and args.fingerprint != ident["fingerprint"]:
        parser.error("Native inputs changed between build planning and checkout")
    if args.command == "identity":
        for key in ("fingerprint", "tag", "runner", "ndk"):
            print(f"{key}={ident[key]}")
        print(f"matrix={json.dumps({'include': ident['targets']})}")
    elif args.command == "probe":
        ready = available(Registry(os.environ["GITHUB_REPOSITORY"]), ident)
        print(f"ready={'true' if ready else 'false'}")
        print(f"fingerprint={ident['fingerprint']}")
        print(f"matrix={json.dumps({'include': ident['targets']})}")
        print(f"runner={ident['runner']}")
        print(f"ndk={ident['ndk']}")
    elif args.command == "pack":
        if args.directory is None or args.output is None or args.api is None or args.abi is None:
            parser.error("pack requires --directory, --output, --api and --abi")
        print(pack(args.directory, args.output, args.api, args.abi))
    elif args.command == "download":
        if args.output is None or args.api is None:
            parser.error("download requires --output and --api")
        download(Registry(os.environ["GITHUB_REPOSITORY"]), args.output, args.api)
    elif args.command == "publish":
        if args.directory is None:
            parser.error("publish requires --directory")
        publish(Registry(os.environ["GITHUB_REPOSITORY"]), args.directory)
    else:
        tools = json.loads((ROOT / NATIVE / "toolchain.json").read_text())
        import sys
        if f"{sys.version_info.major}.{sys.version_info.minor}" != tools["python"]:
            parser.error("Native builder must use the toolchain's Python version")
        subprocess.run(["sudo", "apt-get", "update"], check=True)
        subprocess.run(["sudo", "apt-get", "install", "-y", "--no-install-recommends", *tools["packages"]], check=True)


if __name__ == "__main__":
    main()
