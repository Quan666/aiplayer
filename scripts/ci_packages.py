#!/usr/bin/env python3
"""Plan CI packages, sign isolated transfers, and explain final downloads."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from publish_release import read_version, release_assets
from validate_apk import digest

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("all", "android", "android-legacy", "macos")


def android_matrix(target: str) -> dict:
    profiles = []
    if target in ("all", "android"):
        profiles.append(dict(profile="modern", flutter="3.47.7", api=24,
                             abis="armeabi-v7a arm64-v8a x86_64"))
    if target in ("all", "android", "android-legacy"):
        profiles.append(dict(profile="legacy", flutter="3.32.8", api=23,
                             abis="armeabi-v7a arm64-v8a"))
    return {"include": profiles}


def sign_packages(directory: Path, target: str) -> None:
    from sign_android_apk import sign

    variants = [("android", "universal", False), ("android-arm64", "arm64", False)] if target != "android-legacy" else []
    variants.append(("android-legacy", "universal", True))
    expected = {name for name, _, _ in variants}
    if {path.name for path in directory.iterdir()} != expected:
        raise ValueError(f"Expected only current unsigned variants: {sorted(expected)}")
    encoded = os.environ.pop("ANDROID_KEYSTORE_BASE64", "")
    try:
        for name, abi, legacy in variants:
            os.environ["ANDROID_KEYSTORE_BASE64"] = encoded
            sign(directory / name, ROOT / "artifacts", abi, android_legacy=legacy)
    finally:
        os.environ.pop("ANDROID_KEYSTORE_BASE64", None)
        encoded = ""


def package_summary(directory: Path, target: str, version: str) -> str:
    # This job describes just its own platform; release_assets rejects omissions.
    selected = "android" if target == "all" else target
    assets = release_assets(directory, version, selected)
    descriptions = {
        "android": ("安卓通用", "Android 7.0+", "ARM32 / ARM64 / x86_64", "UNIVERSAL_URL"),
        "android-arm64": ("安卓 ARM64", "Android 7.0+", "仅 ARM64，下载更小", "ARM64_URL"),
        "android-legacy": ("安卓兼容版", "Android 6.0 / 6.0.1+", "ARM32 / ARM64，旧手机及电视", "LEGACY_URL"),
        "macos": ("macOS", "macOS 12+", "Apple Silicon / Intel", "MACOS_URL"),
    }
    rows = [f"版本：`{version}`\n", "| 安装包 | 系统 | 架构 / 用途 | 大小 |", "| --- | --- | --- | --- |"]
    checksums = []
    for asset in assets:
        key = "macos" if asset.suffix == ".zip" else asset.stem.removeprefix(f"aiplayer-{version.split('+')[0]}-")
        title, system, architecture, variable = descriptions[key]
        url = os.environ.get(variable)
        link = f"[{asset.name}]({url})" if url else f"`{asset.name}`"
        rows.append(f"| {title} · {link} | {system} | {architecture} | {asset.stat().st_size / 1024**2:.1f} MiB |")
        checksums.append(f"{digest(asset)}  {asset.name}")
    rows.extend(["", "<details><summary>SHA-256 校验</summary>\n", "```text", *checksums, "```", "</details>"])
    if selected == "macos":
        rows.extend(["", "ZIP 解压得到 aiplayer.app，拖入 Applications。ad-hoc 签名、未公证，首次打开可能需在系统隐私与安全性设置中允许。",
                     "本自用包的本地凭据为仅当前用户可读写的未加密文件；从旧钥匙串版本升级需重填 Token，或从加密同步恢复。",
                     "<details><summary>本次 CocoaPods 依赖锁</summary>\n", "```text"])
        lock = ROOT / "client/macos/Podfile.lock"
        rows.extend([lock.read_text() if lock.is_file() else "未生成依赖锁", "```", "</details>"])
    else:
        native = os.environ.get("NATIVE_FINGERPRINT", "")
        repo = os.environ.get("GITHUB_REPOSITORY", "")
        if native and repo:
            rows.extend(["", f"播放依赖：[native-android-{native[:12]}](https://github.com/{repo}/releases/tag/native-android-{native})"])
        rows.extend(["", "三个版本使用同一应用 ID 和原证书；通用版及 ARM64 版要求 Android 7+，Android 6.0.1 请下载 legacy。",
                     "兼容版使用独立 Flutter 3.32.8 / Dart 3.8.1、API 23 和双 ARM 原生库。",
                     "<details><summary>APK 校验记录</summary>\n", "```json"])
        reports = [json.loads(path.read_text()) for path in sorted(directory.glob("build-android*.json"))]
        rows.extend([json.dumps(reports, ensure_ascii=False, indent=2), "```", "</details>"])
    rows.extend(["", "CI 静态校验通过不代表 Android 6.0.1 / Android TV 真机安装、播放、遥控或功耗已验证。"])
    return "\n".join(rows) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "sign", "summary"))
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    if args.command == "plan":
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"android_profiles={json.dumps(android_matrix(args.target))}\n")
        return
    if args.directory is None:
        parser.error("--directory is required for signing and summaries")
    if args.command == "sign":
        if args.target == "macos":
            parser.error("macOS has no Android signing stage")
        sign_packages(args.directory, args.target)
    else:
        # Check descriptions and checksums before appending a partial summary.
        summary = package_summary(args.directory, args.target, read_version(ROOT / "client/pubspec.yaml"))
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write(summary)


if __name__ == "__main__":
    main()
