#!/usr/bin/env python3
"""Generate an original, tiny two-track PGS MKV for the native player test.

Requires ffmpeg. No downloaded media, fonts, or movie subtitle data are used:
the video is a solid background and the subtitle bitmaps are geometric shapes.

    python3 scripts/make_pgs_fixture.py [output.mkv]
"""

import argparse
from pathlib import Path
import struct
import subprocess
import tempfile


WIDTH, HEIGHT = 640, 360
BITMAP_WIDTH, BITMAP_HEIGHT = 240, 48
X, Y = 200, 280


def segment(kind: int, payload: bytes, seconds: float) -> bytes:
    timestamp = round(seconds * 90_000)
    return b"PG" + struct.pack(">IIBH", timestamp, timestamp, kind, len(payload)) + payload


def composition(number: int, visible: bool) -> bytes:
    # 0x20 = 24 fps; each display set starts a self-contained epoch (0x80).
    payload = struct.pack(">HHBHBBBB", WIDTH, HEIGHT, 0x20, number, 0x80, 0, 0, int(visible))
    if visible:
        payload += struct.pack(">HBBHH", 0, 0, 0, X, Y)
    return payload


def bitmap(variant: int) -> bytes:
    """PGS run lengths for either two bars or a rectangular outline."""
    data = bytearray()
    for y in range(BITMAP_HEIGHT):
        row = []
        for x in range(BITMAP_WIDTH):
            if variant == 0:
                opaque = 5 <= y < 19 or 29 <= y < 43
            else:
                opaque = x < 8 or x >= BITMAP_WIDTH - 8 or y < 8 or y >= BITMAP_HEIGHT - 8
            row.append(1 if opaque else 0)
        start = 0
        while start < len(row):
            end = start + 1
            while end < len(row) and row[end] == row[start]:
                end += 1
            run = end - start
            # A colored, extended run (00 11xxxxxx xxxxxxxx color).
            data.extend((0, 0xC0 | (run >> 8), run & 255, row[start]))
            start = end
        data.extend((0, 0))  # End of bitmap line.
    return bytes(data)


def display_set(seconds: float, number: int, variant: int, visible: bool) -> bytes:
    parts = [segment(0x16, composition(number, visible), seconds)]
    if visible:
        window = struct.pack(">BBHHHH", 1, 0, X, Y, BITMAP_WIDTH, BITMAP_HEIGHT)
        # Palette header followed by transparent black and opaque near-white,
        # with each entry encoded as index, Y, Cr, Cb, alpha.
        palette = bytes((0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255))
        pixels = bitmap(variant)
        obj = struct.pack(">HBB", 0, 0, 0xC0)
        obj += (len(pixels) + 4).to_bytes(3, "big")
        obj += struct.pack(">HH", BITMAP_WIDTH, BITMAP_HEIGHT) + pixels
        parts += [segment(0x17, window, seconds), segment(0x14, palette, seconds), segment(0x15, obj, seconds)]
    parts.append(segment(0x80, b"", seconds))
    return b"".join(parts)


def generate(output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aiplayer-pgs-") as work:
        subtitles = []
        for variant in range(2):
            path = Path(work) / f"track-{variant}.sup"
            path.write_bytes(b"".join(
                display_set(seconds, number, variant, visible)
                for number, (seconds, visible) in enumerate(
                    ((0.5, True), (5.5, False), (6.5, True), (11.5, False))
                )
            ))
            subtitles.append(path)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", f"color=c=0x183047:size={WIDTH}x{HEIGHT}:rate=24:duration=12",
            "-i", str(subtitles[0]), "-i", str(subtitles[1]),
            "-map", "0:v:0", "-map", "1:s:0", "-map", "2:s:0",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "32",
            "-g", "24", "-pix_fmt", "yuv420p", "-c:s", "copy",
            "-metadata", "title=AIPlayer synthetic PGS regression fixture",
            "-metadata:s:s:0", "language=chi", "-metadata:s:s:0", "title=Japanese-CHS[NEST]",
            "-metadata:s:s:1", "language=chi", "-metadata:s:s:1", "title=Japanese-CHT[NEST]",
            "-disposition:s:0", "default", "-disposition:s:1", "0",
            str(output),
        ], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=Path("/tmp/aiplayer-pgs-fixture.mkv"))
    args = parser.parse_args()
    generate(args.output)
    print(args.output)


if __name__ == "__main__":
    main()
