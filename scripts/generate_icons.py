#!/usr/bin/env python3
"""Render the checked-in SVG mark into native launcher assets.

Run with system Python on Debian/Ubuntu after installing python3-gi and
gir1.2-gdkpixbuf-2.0 / librsvg2-common. No Flutter or remote service is used.
Apple icons are opaque RGB squares; platform masks supply their corners.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path
import struct
import xml.etree.ElementTree as ET

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "client"
BRANDING = CLIENT / "assets/branding"
BLUE = "#176BE8"
SVG = (BRANDING / "app_icon.svg").read_text()
PATH = ET.fromstring(SVG).find("{http://www.w3.org/2000/svg}path").attrib["d"]


def svg(*, rounded: bool = False, adaptive: bool = False, monochrome: bool = False) -> str:
    radius = ' rx="220"' if rounded else ""
    color = "#E8EDF5" if monochrome else BLUE
    fill = "#34465D" if monochrome else "#FFFFFF"
    transform = ' transform="translate(81.92 81.92) scale(.84)"' if adaptive else ""
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        f'<rect width="1024" height="1024" fill="{color}"{radius}/>'
        f'<path fill="{fill}" fill-rule="evenodd" d="{PATH}"{transform}/></svg>'
    )


def render(source: str, size: int, *, opaque: bool = False) -> bytes:
    loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
    loader.set_size(size, size)
    loader.write(source.encode())
    loader.close()
    pixels = loader.get_pixbuf()
    if opaque and pixels.get_has_alpha():
        raw = pixels.get_pixels()
        stride = pixels.get_rowstride()
        rgb = bytearray()
        for y in range(size):
            for x in range(size):
                offset = y * stride + x * 4
                assert raw[offset + 3] == 255, "Apple icons must be opaque"
                rgb.extend(raw[offset : offset + 3])
        pixels = GdkPixbuf.Pixbuf.new_from_bytes(
            GLib.Bytes.new(bytes(rgb)), GdkPixbuf.Colorspace.RGB, False, 8, size, size, size * 3
        )
    return bytes(pixels.save_to_bufferv("png", [], [])[1])


def write(path: Path, data: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        path.write_text(data)
    else:
        path.write_bytes(data)


def main() -> None:
    write(BRANDING / "app_icon.png", render(SVG, 512, opaque=True))
    # Legacy Android launchers do not mask icons; include the corner treatment.
    resources = CLIENT / "android/app/src/main/res"
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        write(resources / f"mipmap-{density}/ic_launcher.png", render(svg(rounded=True), size))
    write(
        resources / "values/ic_launcher_colors.xml",
        f'<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="ic_launcher_background">{BLUE}</color></resources>\n',
    )
    vector = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" '
        'android:viewportWidth="1024" android:viewportHeight="1024">\n'
        '    <group android:pivotX="512" android:pivotY="512" android:scaleX="0.84" android:scaleY="0.84">\n'
        f'        <path android:fillColor="#FFFFFF" android:fillType="evenOdd" android:pathData="{PATH}"/>\n'
        '    </group>\n</vector>\n'
    )
    write(resources / "drawable/ic_launcher_foreground.xml", vector)
    write(resources / "drawable/ic_launcher_monochrome.xml", vector)
    write(
        resources / "drawable/splash_logo.xml",
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="72dp" android:height="72dp" android:viewportWidth="1024" android:viewportHeight="1024">\n'
        f'    <path android:fillColor="{BLUE}" android:pathData="M220 0H804Q1024 0 1024 220V804Q1024 1024 804 1024H220Q0 1024 0 804V220Q0 0 220 0Z"/>\n'
        f'    <path android:fillColor="#FFFFFF" android:fillType="evenOdd" android:pathData="{PATH}"/>\n</vector>\n',
    )
    for qualifier, monochrome in [("v26", ""), ("v33", '    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n')]:
        write(
            resources / f"mipmap-anydpi-{qualifier}/ic_launcher.xml",
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <background android:drawable="@color/ic_launcher_background"/>\n'
            '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
            f'{monochrome}</adaptive-icon>\n',
        )
    for platform in ["ios", "macos"]:
        directory = CLIENT / platform / "Runner/Assets.xcassets/AppIcon.appiconset"
        for entry in json.loads((directory / "Contents.json").read_text())["images"]:
            size = round(float(entry["size"].split("x")[0]) * float(entry["scale"].rstrip("x")))
            write(directory / entry["filename"], render(SVG, size, opaque=True))
    launch = CLIENT / "ios/Runner/Assets.xcassets/LaunchImage.imageset"
    for scale in [1, 2, 3]:
        suffix = "" if scale == 1 else f"@{scale}x"
        write(launch / f"LaunchImage{suffix}.png", render(svg(rounded=True), 80 * scale))
    sizes = [16, 24, 32, 48, 64, 128, 256]
    images = [render(svg(rounded=True), size) for size in sizes]
    offset = 6 + 16 * len(images)
    entries = bytearray()
    for size, image in zip(sizes, images):
        entries.extend(struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(image), offset))
        offset += len(image)
    write(CLIENT / "windows/runner/resources/app_icon.ico", struct.pack("<HHH", 0, 1, len(images)) + entries + b"".join(images))
    write(CLIENT / "linux/runner/resources/app_icon.png", render(svg(rounded=True), 512))
    # A checked-in contact sheet helps review launcher shapes without a device.
    previews = [("App", SVG), ("Android", svg(adaptive=True)), ("Monochrome", svg(adaptive=True, monochrome=True)), ("Desktop", svg(rounded=True))]
    cells = []
    for index, (label, source) in enumerate(previews):
        x = index * 224 + 32
        data = base64.b64encode(render(source, 160)).decode()
        clip = f'<clipPath id="mask{index}"><circle cx="{x + 80}" cy="112" r="80"/></clipPath>' if index in [1, 2] else ""
        mask = f' clip-path="url(#mask{index})"' if clip else ""
        cells.append(f'{clip}<image x="{x}" y="32" width="160" height="160" href="data:image/png;base64,{data}"{mask}/><text x="{x + 80}" y="226" text-anchor="middle" fill="#334155" font-family="sans-serif" font-size="18">{label}</text>')
    sheet = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="896" height="256"><rect width="896" height="256" fill="#F5F7FA"/>' + "".join(cells).replace(' href="', ' xlink:href="') + '</svg>'
    loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
    loader.write(sheet.encode())
    loader.close()
    write(BRANDING / "icon_preview.png", bytes(loader.get_pixbuf().save_to_bufferv("png", [], [])[1]))
    print("Generated Android adaptive/monochrome + legacy, iOS, macOS, Windows and Linux icons.")


if __name__ == "__main__":
    main()
