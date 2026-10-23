#!/usr/bin/env python3
"""Exercise an extracted Linux release through X11 input, without Flutter tooling.

Runs in its own Xvfb and D-Bus session. XTest is used when xdotool is unavailable.
This verifies client-area resizing and restoration; Xvfb alone does not provide
a window manager, so desktop keep-above policy is explicitly not asserted.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import shutil


ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"


class XInput:
    def __init__(self):
        self.x11 = ctypes.CDLL("libX11.so.6")
        self.xtst = ctypes.CDLL("libXtst.so.6")
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XFlush.argtypes = [ctypes.c_void_p]
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.xtst.XTestFakeMotionEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong
        ]
        self.xtst.XTestFakeButtonEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong
        ]
        self.display = self.x11.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("Unable to open isolated X11 display")

    def move(self, x, y):
        self.xtst.XTestFakeMotionEvent(self.display, -1, round(x), round(y), 0)
        self.x11.XFlush(self.display)

    def click(self, x, y):
        self.move(x, y)
        time.sleep(0.12)
        self.xtst.XTestFakeButtonEvent(self.display, 1, True, 0)
        self.x11.XFlush(self.display)
        time.sleep(0.06)
        self.xtst.XTestFakeButtonEvent(self.display, 1, False, 0)
        self.x11.XFlush(self.display)

    def close(self):
        self.x11.XCloseDisplay(self.display)


def wait_for(check, *, timeout=20, description="condition", process=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError(f"Release exited while waiting for {description}: {process.returncode}")
        value = check()
        if value:
            return value
        time.sleep(0.15)
    raise RuntimeError(f"Timed out waiting for {description}")


def application_window():
    tree = subprocess.check_output(["xwininfo", "-root", "-tree"], text=True)
    match = re.search(r'(0x[0-9a-fA-F]+) "映库"', tree)
    if not match:
        return None
    window = match[1]
    info = subprocess.check_output(["xwininfo", "-id", window], text=True)
    return window if "Map State: IsViewable" in info else None


def geometry(window):
    info = subprocess.check_output(["xwininfo", "-id", window], text=True)
    def field(label):
        match = re.search(rf"{re.escape(label)}:\s*(-?\d+)", info)
        if match is None:
            raise RuntimeError(f"Missing window geometry: {label}")
        return int(match[1])
    return {
        "x": field("Absolute upper-left X"),
        "y": field("Absolute upper-left Y"),
        "width": field("Width"),
        "height": field("Height"),
    }


def button(bounds, *, pip):
    side = min(76, max(16, bounds["width"] * 0.055))
    top = min(48, max(10, bounds["height"] * 0.055))
    return bounds["x"] + side + (118 if pip else 22), bounds["y"] + top + 22


def progress(database):
    with sqlite3.connect(database, timeout=2) as connection:
        rows = connection.execute("SELECT data FROM records WHERE kind='progress' AND deleted=0").fetchall()
    values = [json.loads(row[0]) for row in rows]
    return max(values, key=lambda value: value.get("updatedAt", ""), default={})


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def run_inside(arguments):
    import gi
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, GdkPixbuf

    def frame_sample(bounds):
        # Sample the middle of the picture, excluding the chrome and timestamp
        # labels. A moving testsrc2 fixture must advance decoded video frames.
        pixels = Gdk.pixbuf_get_from_window(
            Gdk.get_default_root_window(), bounds["x"] + bounds["width"] // 4,
            bounds["y"] + bounds["height"] // 3, bounds["width"] // 2,
            bounds["height"] // 3,
        )
        data = bytes(pixels.get_pixels())
        return {"sha256": hashlib.sha256(data).hexdigest(),
                "byteRange": max(data) - min(data)}

    def capture(name, bounds=None):
        window = Gdk.get_default_root_window()
        if bounds is None:
            bounds = {"x": 0, "y": 0, "width": 1600, "height": 1000}
        pixels = Gdk.pixbuf_get_from_window(window, bounds["x"], bounds["y"], bounds["width"], bounds["height"])
        if pixels is None:
            raise RuntimeError("Unable to capture release window")
        target = ARTIFACTS / name
        pixels.savev(str(target), "png", [], [])
        return target.name

    ARTIFACTS.mkdir(exist_ok=True)
    archive = Path(arguments.archive).resolve()
    evidence = {
        "archive": archive.name,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "isolatedData": True,
        "display": "Independent Xvfb 1600x1000; XTest input; no window manager",
        "keepAboveVerified": False,
        "excludedEnvironment": ["LD_LIBRARY_PATH", "JAVA_HOME", "JDK_HOME"],
        "platform": "Linux x64",
        "success": False,
    }
    manifest = json.loads((ARTIFACTS / "build-linux.json").read_text())
    expected = next(item for item in manifest["artifact_details"] if item["name"] == archive.name)
    assert evidence["sha256"] == expected["sha256"], "Archive does not match build-linux.json"
    assert archive.stat().st_size == expected["size_bytes"], "Archive size does not match build-linux.json"
    tag = re.sub(r"[^0-9A-Za-z]", "", manifest["version"].split("+")[0])
    evidence["version"] = manifest["version"]
    evidence["matchesBuildManifest"] = True
    process = None
    input_device = XInput()
    with tempfile.TemporaryDirectory(prefix="aiplayer-release-pip-") as temporary:
        temporary = Path(temporary)
        with tarfile.open(archive) as bundle:
            bundle.extractall(temporary, filter="data")
        application = temporary / "aiplayer-linux-x64"
        assert not (application / "lib/libdartjni.so").exists()
        env = {key: value for key, value in os.environ.items() if key not in ["LD_LIBRARY_PATH", "JAVA_HOME", "JDK_HOME"]}
        env.update(
            XDG_CONFIG_HOME=str(temporary / "config"), XDG_DATA_HOME=str(temporary / "data"),
            XDG_CACHE_HOME=str(temporary / "cache"), LIBGL_ALWAYS_SOFTWARE="1", GDK_BACKEND="x11",
        )
        with (ARTIFACTS / f"linux-pip-release-{tag}.log").open("w+") as log:
            try:
                process = subprocess.Popen([str(application / "launch.sh")], cwd=application, env=env, stdout=log, stderr=log)
                first_window = wait_for(application_window, description="bootstrap first frame", process=process)
                database = wait_for(lambda: next((temporary / "data").rglob("library.db"), None), process=process)
                time.sleep(0.6)
                evidence["firstFrame"] = {"visible": True,
                                          "screenshot": capture(f"linux_pip_{tag}_first_frame.png", geometry(first_window))}
                stop(process)
                process = None
                # Isolate this check from online metadata and fullscreen window
                # manager behavior. Player chrome and hide timing keep defaults.
                with sqlite3.connect(database) as connection:
                    connection.execute("INSERT OR REPLACE INTO local(key,value) VALUES(?,?)", (
                        "settings", json.dumps({"metadataStrategy": "off", "enterFullscreen": False}),
                    ))
                fixture = temporary / "Example S01E01.mkv"
                subprocess.run([
                    "ffmpeg", "-v", "error", "-nostdin", "-stream_loop", "2", "-i", arguments.fixture,
                    "-t", "90", "-map", "0", "-c", "copy", str(fixture),
                ], check=True)
                process = subprocess.Popen([str(application / "launch.sh"), fixture.as_uri()], cwd=application, env=env, stdout=log, stderr=log)
                window = wait_for(application_window, description="playback window", process=process)
                initial = geometry(window)
                first_progress = wait_for(lambda: (value if (value := progress(database)).get("position", 0) > 0 else None),
                                          description="actual playback progress", process=process)
                input_device.move(initial["x"] + 200, initial["y"] + 150)
                time.sleep(0.3)
                evidence["before"] = {"geometry": initial, "progress": first_progress,
                                      "screenshot": capture(f"linux_pip_{tag}_before.png", initial)}
                input_device.click(*button(initial, pip=True))
                floating = wait_for(lambda: (value if (value := geometry(window))["width"] < 700 else None),
                                    timeout=8, description="native floating window resize", process=process)
                assert abs(floating["width"] - 480) <= 4 and abs(floating["height"] - 270) <= 4, floating
                time.sleep(6)
                frame_one = frame_sample(floating)
                time.sleep(1.2)
                frame_two = frame_sample(floating)
                assert frame_one["byteRange"] > 32 and frame_two["byteRange"] > 32, "Video sample is blank"
                assert frame_one["sha256"] != frame_two["sha256"], "Decoded video did not advance in floating window"
                evidence["decodedFrames"] = {"first": frame_one, "second": frame_two, "changed": True}
                input_device.move(floating["x"] + 150, floating["y"] + 95)
                time.sleep(0.3)
                floated_progress = progress(database)
                assert floated_progress.get("position", 0) > first_progress["position"], floated_progress
                evidence["floating"] = {"geometry": floating, "progress": floated_progress,
                                        "screenshot": capture(f"linux_pip_{tag}_floating.png", floating),
                                        "desktopScreenshot": capture(f"linux_pip_{tag}_desktop.png")}
                input_device.click(*button(floating, pip=True))
                restored = wait_for(lambda: (value if (value := geometry(window))["width"] == initial["width"]
                                            and value["height"] == initial["height"] else None),
                                    timeout=8, description="original window dimensions", process=process)
                input_device.move(restored["x"] + 200, restored["y"] + 150)
                time.sleep(0.3)
                evidence["restored"] = {"geometry": restored,
                                        "screenshot": capture(f"linux_pip_{tag}_restored.png", restored)}
                input_device.click(*button(restored, pip=False))
                saved = wait_for(lambda: (value if (value := progress(database)).get("updatedAt", "")
                                         > floated_progress.get("updatedAt", "") else None),
                                 timeout=8, description="progress saved on player return", process=process)
                def current_cover():
                    with sqlite3.connect(database, timeout=2) as connection:
                        rows = connection.execute("SELECT value FROM local WHERE key LIKE 'preview:%'").fetchall()
                    for row in rows:
                        value = json.loads(row[0])
                        if abs(value.get("requestedPosition", -100) - saved["position"]) < 1.5 and Path(value["path"]).is_file():
                            return value
                    return None
                cover = wait_for(current_cover, timeout=8, description="latest progress cover", process=process)
                assert abs(cover["capturedPosition"] - saved["position"]) < 1.5, cover
                cover_pixels = GdkPixbuf.Pixbuf.new_from_file(cover["path"])
                raw_pixels = bytes(cover_pixels.get_pixels())
                assert max(raw_pixels) - min(raw_pixels) > 32, "Saved cover is blank"
                assert max(cover_pixels.get_width(), cover_pixels.get_height()) <= 480
                cover_name = f"linux_pip_{tag}_resume_cover.jpg"
                shutil.copyfile(cover["path"], ARTIFACTS / cover_name)
                evidence["returned"] = {"progress": saved,
                                        "cover": {"file": cover_name, "requestedPosition": cover["requestedPosition"], "capturedPosition": cover["capturedPosition"], "formatVersion": cover["formatVersion"]},
                                        "screenshot": capture(f"linux_pip_{tag}_returned.png", geometry(window))}
                log.flush()
                log.seek(0)
                output = log.read()
                failures = re.findall(r"(?:A RenderFlex overflowed[^\n]*|Unhandled Exception[^\n]*|Another exception was thrown[^\n]*)", output)
                assert not failures, failures
                evidence["runtimeErrors"] = failures
                evidence["success"] = True
                print(json.dumps(evidence, ensure_ascii=False))
            except Exception as error:
                evidence["error"] = str(error)
                evidence["failureScreenshot"] = capture(f"linux_pip_{tag}_failed.png")
                raise
            finally:
                stop(process)
                input_device.close()
                (ARTIFACTS / f"linux-pip-release-{tag}.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", default=str(ARTIFACTS / "aiplayer-linux-x64.tar.gz"))
    parser.add_argument("--fixture", default="/tmp/aiplayer-media-fixture/Example S01E01.mkv")
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.inside:
        run_inside(arguments)
    else:
        subprocess.run([
            "dbus-run-session", "--", "xvfb-run", "-a", "-s", "-screen 0 1600x1000x24",
            sys.executable, str(Path(__file__).resolve()), "--inside", "--archive", arguments.archive,
            "--fixture", arguments.fixture,
        ], check=True)


if __name__ == "__main__":
    main()
