#!/usr/bin/env python3
"""Generate first-frame and asymmetric orientation fixtures for album capture."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("/tmp/album-video-fixtures"))
    root = parser.parse_args().output
    root.mkdir(parents=True, exist_ok=True)

    def ffmpeg(*args):
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args),
        ], check=True)

    codec = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-an"]
    for name, source in [
        ("first", "color=c=red:s=360x640:r=12:d=2,"
                  "drawbox=x=0:y=0:w=iw:h=ih:color=blue:t=fill:enable='gte(t,0.25)'"),
        ("black", "color=c=black:s=360x640:r=12:d=2"),
        ("orientation-unrotated", "color=c=red:s=1920x1080:r=12:d=2,"
         "drawbox=x=960:y=0:w=960:h=540:color=lime:t=fill,"
         "drawbox=x=0:y=540:w=960:h=540:color=blue:t=fill,"
         "drawbox=x=960:y=540:w=960:h=540:color=yellow:t=fill"),
    ]:
        ffmpeg("-f", "lavfi", "-i", source, *codec, root / f"{name}.mp4")

    base = root / "orientation-unrotated.mp4"
    for name, angle in [("orientation", 90), ("orientation-270", 270)]:
        ffmpeg("-display_rotation:v:0", angle, "-i", base, "-c", "copy",
               root / f"{name}.mp4")
    ffmpeg("-i", base, "-vf", "transpose=clock", *codec, root / "portrait.mp4")
    for name in ["orientation-unrotated", "orientation", "orientation-270", "portrait"]:
        ffmpeg("-i", root / f"{name}.mp4", "-frames:v", "1",
               root / f"{name}-reference.png")
    print(root)


if __name__ == "__main__":
    main()
