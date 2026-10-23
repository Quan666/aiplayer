#!/usr/bin/env python3
"""Small, deterministic MKV files exercising blank frames and precise seeks."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("/tmp/aiplayer-preview-051"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    filters = (
        "drawbox=x=0:y=0:w=iw:h=ih:color=black:t=fill:"
        "enable='lt(t,4)+between(t,14,18)',"
        "drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:"
        "enable='between(t,4,8)+between(t,24,28)',"
        "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:"
        "text='%{pts\\:hms}':fontsize=20:x=10:y=10:fontcolor=white:"
        "box=1:boxcolor=black@0.5:"
        "enable='between(t,8,14)+between(t,18,24)+gte(t,28)'"
    )
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
        "-i", "testsrc2=size=320x180:rate=24:duration=30", "-vf", filters,
        "-c:v", "libx264", "-preset", "veryfast", "-g", "240", "-bf", "3",
        "-pix_fmt", "yuv420p", str(args.output / "h264.mkv"),
    ], check=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(args.output / "h264.mkv"), "-c:v", "libx265", "-preset", "veryfast",
        "-x265-params", "pools=1:frame-threads=1:keyint=240:bframes=3:log-level=error",
        "-pix_fmt", "yuv420p10le", str(args.output / "hevc10.mkv"),
    ], check=True)
    print(args.output)


if __name__ == "__main__":
    main()
