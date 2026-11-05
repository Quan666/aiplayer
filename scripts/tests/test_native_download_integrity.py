"""Native archive caches must pass SHA-256 before build inputs are used."""

import contextlib
import functools
import hashlib
import http.server
import io
from pathlib import Path
import shutil
import ssl
import subprocess
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "packages/native_dependencies/verified_download.cmake"


@unittest.skipUnless(shutil.which("cmake"), "CMake is required")
class NativeDownloadIntegrityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = self.directory / "source.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            data = b"verified upstream source\n"
            entry = tarfile.TarInfo("upstream/source.c")
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def cmake(self, commands):
        script = self.directory / "verify.cmake"
        script.write_text(f'include("{HELPER.as_posix()}")\n{commands}\n')
        return subprocess.run(
            ["cmake", "-P", str(script)], text=True, capture_output=True, timeout=20
        )

    def download(self, url="https://invalid.example/source.tar.gz"):
        return self.cmake(
            f'aiplayer_download_verified("{url}" "{self.digest}" '
            f'"{self.archive.as_posix()}")'
        )

    @contextlib.contextmanager
    def https_server(self):
        if not shutil.which("openssl"):
            self.skipTest("OpenSSL is required for TLS download regression tests")
        certificate = self.directory / "certificate.pem"
        private_key = self.directory / "key.pem"
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(private_key), "-out", str(certificate),
             "-subj", "/CN=localhost", "-addext",
             "subjectAltName=DNS:localhost,IP:127.0.0.1", "-days", "1"],
            check=True, capture_output=True, timeout=20,
        )
        class QuietHandler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        handler = functools.partial(QuietHandler, directory=str(self.directory))
        try:
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        except PermissionError:
            self.skipTest("the test environment does not permit local sockets")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(certificate), str(private_key))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"https://127.0.0.1:{server.server_port}/payload.tar.gz", certificate
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def fresh_download(self, url, certificate=None):
        trust = (f'set(CMAKE_TLS_CAINFO "{certificate.as_posix()}")\n'
                 if certificate else "")
        return self.cmake(
            trust + f'aiplayer_download_verified("{url}" "{self.digest}" '
            f'"{self.archive.as_posix()}")'
        )

    def test_new_https_download_is_verified_before_commit(self):
        payload = self.directory / "payload.tar.gz"
        self.archive.rename(payload)
        with self.https_server() as (url, certificate):
            result = self.fresh_download(url, certificate)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.archive.read_bytes(), payload.read_bytes())
        self.assertFalse(Path(str(self.archive) + ".part").exists())

    def test_new_download_with_wrong_hash_is_removed(self):
        self.archive.unlink()
        (self.directory / "payload.tar.gz").write_bytes(b"substituted native dependency")
        with self.https_server() as (url, certificate):
            result = self.fresh_download(url, certificate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse(self.archive.exists())
        self.assertFalse(Path(str(self.archive) + ".part").exists())

    def test_untrusted_tls_certificate_is_rejected(self):
        self.archive.rename(self.directory / "payload.tar.gz")
        with self.https_server() as (url, _):
            result = self.fresh_download(url)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("download failed", result.stderr)
        self.assertFalse(self.archive.exists())
        self.assertFalse(Path(str(self.archive) + ".part").exists())

    def test_valid_archive_is_usable_offline(self):
        result = self.download()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_modified_cache_fails_before_it_can_be_used(self):
        self.archive.write_bytes(b"untrusted restored cache")
        result = self.download()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse(self.archive.with_suffix(".gz.part").exists())

    def test_http_is_rejected_even_with_a_valid_cache(self):
        result = self.download("http://invalid.example/source.tar.gz")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require HTTPS", result.stderr)

    def test_symlinked_cache_is_rejected(self):
        target = self.directory / "elsewhere.tar.gz"
        self.archive.rename(target)
        try:
            self.archive.symlink_to(target)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks are unavailable")
        result = self.download()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a regular file", result.stderr)

    def test_restored_extraction_is_replaced_from_verified_archive(self):
        destination = self.directory / "source"
        source = destination / "upstream/source.c"
        source.parent.mkdir(parents=True)
        source.write_text("tampered cached extraction")
        extra = destination / "injected.c"
        extra.write_text("injected cached source")
        result = self.cmake(
            f'aiplayer_extract_verified("{self.archive.as_posix()}" '
            f'"{self.digest}" "{destination.as_posix()}")'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.read_text(), "verified upstream source\n")
        self.assertFalse(extra.exists())

    def test_modified_archive_cannot_overwrite_existing_sources(self):
        destination = self.directory / "source"
        destination.mkdir()
        source = destination / "keep.c"
        source.write_text("previous good extraction")
        self.archive.write_bytes(b"untrusted archive")
        result = self.cmake(
            f'aiplayer_extract_verified("{self.archive.as_posix()}" '
            f'"{self.digest}" "{destination.as_posix()}")'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertEqual(source.read_text(), "previous good extraction")

    def test_failed_download_never_commits_a_partial_archive(self):
        self.archive.unlink()
        result = self.download("https://127.0.0.1:1/unavailable.tar.gz")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("download failed", result.stderr)
        self.assertFalse(self.archive.exists())
        self.assertFalse(Path(str(self.archive) + ".part").exists())


if __name__ == "__main__":
    unittest.main()
