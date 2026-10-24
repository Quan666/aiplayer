#!/usr/bin/env python3
"""Exercise a built image and its data volume on a random loopback port."""
import argparse
import json
import os
import secrets
import subprocess
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--image", default="aiplayer-sync:local")
parser.add_argument("--platform", help="Optional Docker platform, e.g. linux/arm64")
args = parser.parse_args()

token = secrets.token_hex(32)
env = {**os.environ, "SYNC_TOKEN": token}
container = None
volume = "aiplayer-sync-smoke-" + secrets.token_hex(8)


def docker(*command, env=None):
    return subprocess.check_output(
        ["docker", *command], env=env, text=True, timeout=120,
    ).strip()


def start():
    global container
    platform = ["--platform", args.platform] if args.platform else []
    container = docker(
        "run", "--pull=never", "-d", *platform, "-e", "SYNC_TOKEN",
        "--mount", f"type=volume,source={volume},target=/data",
        "-p", "127.0.0.1::8080", args.image, env=env,
    )
    return "http://" + docker("port", container, "8080/tcp")


docker("volume", "create", volume)
try:
    base = start()

    def request(path, body=None, authenticated=True):
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(
            base + path, headers=headers,
            data=None if body is None else json.dumps(body).encode(),
            method="GET" if body is None else "PUT",
        )
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def ready():
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if request("/healthz", authenticated=False)[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(.1)
        raise RuntimeError("container did not become healthy")

    ready()
    assert request("/v1/changes", authenticated=False)[0] == 401
    record = {"id": "fixture", "kind": "watched", "version": 0,
              "deleted": False, "data": {"watched": True}}
    status, saved = request("/v1/records", record)
    assert status == 200 and saved["version"] == 1
    assert request("/v1/records", record)[0] == 409
    assert request("/v1/changes?after=0")[1]["changes"][0]["data"]["watched"]
    metadata = {"id": "metadata-fixture", "kind": "media", "version": 0,
                "deleted": False, "data": {"title": "Fixture", "season": "2",
                    "episode": "3", "metadataProvider": "tmdb", "tmdbId": "123",
                    "metadataTitle": "Fixture", "rating": 8.5,
                    "ratingCount": 200, "totalEpisodes": 12, "totalSeasons": 2,
                    "genres": ["Animation"], "metadataType": "tv"}}
    status, saved_metadata = request("/v1/records", metadata)
    assert status == 200 and saved_metadata["data"]["rating"] == 8.5, (status, saved_metadata)
    leaked = {**metadata, "id": "private-fixture", "data": {**metadata["data"], "apiKey": "private"}}
    assert request("/v1/records", leaked)[0] == 400
    docker("restart", container)
    base = "http://" + docker("port", container, "8080/tcp")
    ready()
    assert request("/v1/changes?after=0")[1]["cursor"] == 2
    assert docker("exec", container, "id", "-u") == "10001"
    assert docker("exec", container, "id", "-g") == "10001"

    # An upgrade creates a new container, so verify the named volume survives it.
    docker("stop", container)
    docker("rm", "-v", container)
    container = None
    base = start()
    ready()
    status, restored = request("/v1/changes?after=0")
    assert status == 200 and restored["cursor"] == 2, (status, restored)
    records = {item["id"]: item for item in restored["changes"]}
    assert records[record["id"]]["data"] == record["data"]
    assert records[metadata["id"]]["data"] == metadata["data"]
    status, updated = request("/v1/records", {**record, "version": 1, "data": {"watched": False}})
    assert status == 200 and updated["version"] == 2, (status, updated)
    assert request("/v1/changes?after=2")[1]["cursor"] == 3
    print("Docker OK: health, bearer auth, version conflict, incremental sync, metadata roundtrip, private fields rejected, restart and recreate persistence, non-root user")
except Exception:
    if container:
        subprocess.run(["docker", "logs", "--tail", "50", container], timeout=15)
    raise
finally:
    try:
        if container:
            docker("rm", "-f", "-v", container)
    finally:
        docker("volume", "rm", volume)
