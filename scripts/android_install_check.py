#!/usr/bin/env python3
"""Install an APK through Android Package Manager and save a narrow diagnostic.

This preserves application data (adb install -r), never uninstalls an existing
app, and collects only device compatibility fields and this install's result.
Use --serial when more than one device or emulator is connected.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

from validate_apk import sdk_root, sdk_tool, validate_apk


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--serial")
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--archive-probe", action="store_true", help="Call the device's getPackageArchiveInfo before installation; requires javac and SDK platforms")
    parser.add_argument("--allow-legacy-signing", action="store_true")
    parser.add_argument("--output", type=Path, default=Path("artifacts/android-install-check.json"))
    arguments = parser.parse_args()
    report = {"apk": validate_apk(arguments.apk, require_all_signatures=not arguments.allow_legacy_signing)}
    adb = [str(sdk_root() / "platform-tools" / ("adb.exe" if os.name == "nt" else "adb"))]
    if arguments.serial:
        adb += ["-s", arguments.serial]

    def command(*args: str, timeout: int = 60) -> subprocess.CompletedProcess:
        return subprocess.run([*adb, *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)

    state = command("get-state")
    if state.returncode or state.stdout.strip() != "device":
        raise RuntimeError(f"Connect and authorize one device, or select --serial: {state.stdout.strip()}")
    report["device"] = {}
    for label, prop in {
        "manufacturer": "ro.product.manufacturer", "model": "ro.product.model",
        "android_version": "ro.build.version.release", "sdk": "ro.build.version.sdk",
        "abis": "ro.product.cpu.abilist",
    }.items():
        report["device"][label] = command("shell", "getprop", prop).stdout.strip()
    page_size = command("shell", "getconf", "PAGE_SIZE")
    if page_size.returncode == 0 and page_size.stdout.strip().isdigit():
        report["device"]["page_size"] = int(page_size.stdout.strip())
    else:
        # Android 7's toolbox does not ship getconf.
        maps = command("shell", "cat", "/proc/self/smaps")
        match = re.search(r"^KernelPageSize:\s+(\d+) kB", maps.stdout, re.MULTILINE)
        report["device"]["page_size"] = int(match.group(1)) * 1024 if match else None
    if arguments.archive_probe:
        platforms = sorted((sdk_root() / "platforms").glob("android-*/android.jar"), key=lambda path: [int(n) for n in re.findall(r"\d+", path.parent.name)], reverse=True)
        if not platforms:
            raise RuntimeError("Archive probe requires an installed Android SDK platform")
        with tempfile.TemporaryDirectory(prefix="aiplayer-archive-probe-") as directory:
            temporary = Path(directory)
            source = Path(__file__).resolve().parent / "android/PackageArchiveProbe.java"
            subprocess.run(["javac", "-source", "8", "-target", "8", "-classpath", str(platforms[0]), "-d", str(temporary), str(source)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run([str(sdk_tool("d8")), "--min-api", "24", "--lib", str(platforms[0]), "--output", str(temporary), str(temporary / "PackageArchiveProbe.class")], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            jar = temporary / "archive-probe.jar"
            with zipfile.ZipFile(jar, "w") as archive:
                archive.write(temporary / "classes.dex", "classes.dex")
            remote_jar = "/data/local/tmp/aiplayer-archive-probe.jar"
            remote_apk = "/data/local/tmp/aiplayer-archive-probe.apk"
            try:
                for local, remote in ((jar, remote_jar), (arguments.apk.resolve(), remote_apk)):
                    pushed = command("push", str(local), remote, timeout=180)
                    if pushed.returncode:
                        raise RuntimeError(pushed.stdout)
                probe = command("shell", f"CLASSPATH={remote_jar}", "app_process", "/system/bin", "PackageArchiveProbe", remote_apk, timeout=180)
                payload = re.search(r"AIPLAYER_ARCHIVE_INFO=(\{.+\})", probe.stdout)
                report["archive_probe"] = json.loads(payload.group(1)) if payload else {"exit_code": probe.returncode, "output": probe.stdout.strip()}
            finally:
                command("shell", "rm", "-f", remote_jar, remote_apk)
    result = command("install", "-r", "--no-streaming", str(arguments.apk.resolve()), timeout=240)
    report["install"] = {"exit_code": result.returncode, "output": result.stdout.strip(), "success": result.returncode == 0 and "Success" in result.stdout}
    if report["install"]["success"]:
        package = report["apk"]["package"]
        report["installed_path"] = command("shell", "pm", "path", package).stdout.strip()
        if arguments.launch:
            launch = command("shell", "am", "start", "-W", "-n", f"{package}/.MainActivity", timeout=120)
            report["launch"] = {"exit_code": launch.returncode, "output": launch.stdout.strip()}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"device": report["device"], "install": report["install"], "report": str(arguments.output)}, ensure_ascii=False, indent=2))
    if not report["install"]["success"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
