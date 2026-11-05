"""Explicit native fixture regression; never changes production signal handling.

Start scripts/smb_fixture.sh, then run with AIPLAYER_SMB_FIXTURE=true.
Optional AIPLAYER_SMB_LIBRARY points to the built libaiplayer_smb.so.
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
LIBRARY = Path(os.environ.get(
    "AIPLAYER_SMB_LIBRARY",
    ROOT / "client/build/linux/x64/release/bundle/lib/libaiplayer_smb.so",
))


@unittest.skipUnless(
    os.name == "posix" and os.environ.get("AIPLAYER_SMB_FIXTURE") == "true",
    "Requires the explicitly started native SMB fixture",
)
class SmbSignalInterruptions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="smb-signals-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.probe = str(Path(cls.temporary.name) / "probe")
        subprocess.run([
            "cc", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
            "-I", str(ROOT / "packages/aiplayer_smb/src/vendor/libsmb2/include"),
            str(Path(__file__).with_name("smb_signal_probe.c")),
            str(LIBRARY.resolve()), "-Wl,-rpath," + str(LIBRARY.resolve().parent),
            "-o", cls.probe,
        ], check=True, capture_output=True, text=True)

    def run_probe(self, *arguments):
        result = subprocess.run(
            [self.probe, *arguments], capture_output=True,
            text=True, timeout=8,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_authenticated_reads_survive_repeated_signals(self):
        result = self.run_probe("read", os.environ.get("USER", "root"))
        self.assertGreater(result["authenticationSignals"], 0)
        self.assertGreater(result["readSignals"], 0)
        self.assertEqual(result["result"], 0)

    def test_signals_do_not_extend_a_stalled_connection_deadline(self):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        server.settimeout(8)
        stop = threading.Event()
        connected = threading.Event()

        def stall():
            try:
                connection, _ = server.accept()
                with connection:
                    connected.set()
                    stop.wait(8)
            except OSError:
                pass

        thread = threading.Thread(target=stall, daemon=True)
        thread.start()
        try:
            result = self.run_probe("timeout", f"127.0.0.1:{server.getsockname()[1]}")
            self.assertTrue(connected.is_set())
            self.assertGreater(result["signals"], 100)
            self.assertGreaterEqual(result["elapsedMillis"], 900)
            self.assertLess(result["elapsedMillis"], 5000)
            self.assertLess(result["result"], 0)
        finally:
            stop.set()
            server.close()
            thread.join(timeout=1)


if __name__ == "__main__":
    unittest.main()
