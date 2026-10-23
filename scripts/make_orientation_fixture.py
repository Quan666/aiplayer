#!/usr/bin/env python3
"""Generate tiny embedded MP4 fixtures for the Android orientation regression."""
import base64
import json
from pathlib import Path
import subprocess
import sys


root = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/aiplayer-orientation-fixture")
root.mkdir(parents=True, exist_ok=True)
defines = {}
for name, size, color in [
    ("landscape", "320x180", "blue"),
    ("portrait", "180x320", "green"),
]:
    target = root / f"{name}.mp4"
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"color=c={color}:size={size}:rate=12", "-t", "3",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "32",
        "-pix_fmt", "yuv420p", "-an", str(target),
    ], check=True)
    defines[f"{name.upper()}_FIXTURE"] = base64.b64encode(target.read_bytes()).decode()
output = root / "defines.json"
output.write_text(json.dumps(defines))
print(output)
