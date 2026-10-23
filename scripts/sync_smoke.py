#!/usr/bin/env python3
"""Exercise the built Docker image on a random loopback port; remove it afterwards."""
import json
import os
import secrets
import subprocess
import time
import urllib.error
import urllib.request

token = secrets.token_hex(32)
env = {**os.environ, "SYNC_TOKEN": token}
container = subprocess.check_output([
    "docker", "run", "--rm", "-d", "-e", "SYNC_TOKEN",
    "-p", "127.0.0.1::8080", "aiplayer-sync:local",
], env=env, text=True).strip()
try:
    address = subprocess.check_output([
        "docker", "port", container, "8080/tcp",
    ], text=True).strip()
    base = "http://" + address

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
        for _ in range(30):
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
    subprocess.run(["docker", "restart", container], check=True, stdout=subprocess.DEVNULL)
    base = "http://" + subprocess.check_output([
        "docker", "port", container, "8080/tcp",
    ], text=True).strip()
    ready()
    assert request("/v1/changes?after=0")[1]["cursor"] == 2
    user = subprocess.check_output(["docker", "exec", container, "id", "-u"], text=True).strip()
    assert user == "10001"
    print("Docker OK: health, bearer auth, version conflict, incremental sync, metadata roundtrip, private fields rejected, restart persistence, non-root user")
finally:
    subprocess.run(["docker", "rm", "-f", "-v", container], check=True, stdout=subprocess.DEVNULL)
