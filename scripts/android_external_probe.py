#!/usr/bin/env python3
"""Build/install a test-only content provider without Gradle or Flutter.

The provider is non-exported. Its Activity sends ACTION_VIEW/ACTION_SEND to the
installed player with an actual temporary content:// read grant. Revoke deletes
the provider's fixture and blocks later reads, allowing persistence checks.
Uses an existing personal-use debug keystore; never generates a private key.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shlex
import subprocess
import tempfile
import zipfile

from validate_apk import sdk_root, sdk_tool


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default="emulator-5554")
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    build.add_argument("--video", type=Path, required=True)
    build.add_argument("--keystore", type=Path, required=True)
    build.add_argument("--output", type=Path, default=Path("/tmp/aiplayer-external-probe.apk"))
    install = commands.add_parser("install")
    install.add_argument("apk", type=Path)
    launch = commands.add_parser("open")
    launch.add_argument("--case", required=True)
    launch.add_argument("--action", choices=["VIEW", "SEND"], default="VIEW")
    launch.add_argument("--name")
    launch.add_argument("--query-delay-ms", type=int, default=0)
    revoke = commands.add_parser("revoke")
    revoke.add_argument("--case", required=True)
    args = parser.parse_args()
    adb = [str(sdk_root() / "platform-tools/adb"), "-s", args.serial]
    if args.command == "build":
        source = Path(__file__).parent / "android/external_probe"
        platforms = sorted((sdk_root() / "platforms").glob("android-*/android.jar"), key=lambda p: int(p.parent.name.split("-")[1]))
        android_jar = platforms[-1]
        with tempfile.TemporaryDirectory(prefix="aiplayer-external-probe-") as directory:
            temporary = Path(directory)
            classes = temporary / "classes"
            dex = temporary / "dex"
            classes.mkdir()
            dex.mkdir()
            unsigned = temporary / "unsigned.apk"
            aligned = temporary / "aligned.apk"
            subprocess.run([str(sdk_tool("aapt2")), "link", "--manifest", str(source / "AndroidManifest.xml"), "-I", str(android_jar), "-o", str(unsigned)], check=True)
            subprocess.run(["javac", "-source", "8", "-target", "8", "-classpath", str(android_jar), "-d", str(classes), *map(str, source.glob("*.java"))], check=True)
            subprocess.run([str(sdk_tool("d8")), "--min-api", "24", "--lib", str(android_jar), "--output", str(dex), *map(str, classes.rglob("*.class"))], check=True)
            with zipfile.ZipFile(unsigned, "a", zipfile.ZIP_DEFLATED) as archive:
                archive.write(dex / "classes.dex", "classes.dex")
                archive.write(args.video, "assets/fixture.mp4")
            subprocess.run([str(sdk_tool("zipalign")), "-f", "4", str(unsigned), str(aligned)], check=True)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(sdk_tool("apksigner")), "sign", "--ks", str(args.keystore), "--ks-pass", "pass:android", "--key-pass", "pass:android", "--out", str(args.output), str(aligned)], check=True)
        print(args.output.resolve())
    elif args.command == "install":
        subprocess.run([*adb, "install", "-r", str(args.apk.resolve())], check=True)
    else:
        # Start a fresh sender even when Android kept its task after finish().
        # These flags apply only to the probe; the target Intent deliberately
        # carries only the real read grant, as an ordinary file manager would.
        command = ["am", "start", "-f", "0x18000000", "-n", "app.aiplayer.externalprobe/.ExternalProbeActivity", "--es", "case", args.case]
        if args.command == "revoke":
            command += ["--ez", "revoke", "true"]
        else:
            command += ["--es", "action", args.action, "--ei", "query_delay_ms", str(args.query_delay_ms)]
            if args.name:
                command += ["--es", "name", args.name]
        subprocess.run([*adb, "shell", shlex.join(command)], check=True)


if __name__ == "__main__":
    main()
