"""Check executable resolution, including real .bat launch on Windows CI."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "packager", Path(__file__).resolve().parents[1] / "package.py"
)
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageCommandTest(unittest.TestCase):
    def test_resolves_batch_tool_without_changing_arguments(self):
        with tempfile.TemporaryDirectory(prefix="aiplayer-tools-") as directory:
            executable = Path(directory) / "SDK with spaces/flutter.bat"
            command = ["flutter", "build", "windows", "--release"]
            with patch.object(packager.shutil, "which", return_value=str(executable)) as lookup, \
                 patch.object(packager.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "version\n")) as launch:
                self.assertEqual(packager.run(command, cwd=Path(directory), capture=True), "version\n")
                lookup.assert_called_once_with("flutter")
                launch.assert_called_once_with(
                    [str(executable.resolve()), "build", "windows", "--release"],
                    cwd=Path(directory), check=True, text=True, stdout=subprocess.PIPE,
                )
                self.assertEqual(command[0], "flutter")

    def test_missing_tool_fails_before_launch(self):
        with patch.object(packager.shutil, "which", return_value=None), \
             patch.object(packager.subprocess, "run") as launch:
            with self.assertRaisesRegex(FileNotFoundError, "Build tool not found: flutter"):
                packager.run(["flutter", "build", "windows"])
            launch.assert_not_called()

    @unittest.skipUnless(os.name == "nt", "Requires native Windows batch execution")
    def test_windows_batch_lookup_spaces_and_exit_status(self):
        with tempfile.TemporaryDirectory(prefix="aiplayer batch test ") as directory:
            root = Path(directory)
            tools = root / "SDK with spaces"
            tools.mkdir()
            working = root / "working"
            working.mkdir()
            batch = tools / "aiplayer_test_tool.bat"
            batch.write_bytes(b'@echo off\r\necho argument:%~1\r\nexit /b 0\r\n')
            with patch.dict(os.environ, {
                "PATH": str(tools) + os.pathsep + os.environ.get("PATH", ""),
                "PATHEXT": ".COM;.EXE;.BAT;.CMD",
            }):
                output = packager.run(["aiplayer_test_tool", "value with spaces"], cwd=working, capture=True)
                self.assertEqual(output.strip(), "argument:value with spaces")
                batch.write_bytes(b'@echo off\r\nexit /b 7\r\n')
                with self.assertRaises(subprocess.CalledProcessError) as error:
                    packager.run(["aiplayer_test_tool"], cwd=working, capture=True)
                self.assertEqual(error.exception.returncode, 7)


if __name__ == "__main__":
    unittest.main()
