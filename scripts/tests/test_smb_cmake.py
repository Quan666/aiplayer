"""Build the SMB plugin from repository sources, without local vendor extras."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("packages/aiplayer_smb/src")


@unittest.skipUnless(shutil.which("cmake") and shutil.which("git"), "CMake and Git are required")
class SmbCMakeTest(unittest.TestCase):
    def test_tracked_sources_configure_and_build(self):
        # A vendor .gitignore can hide required inputs in a developer checkout.
        # Copy tracked working-tree files so edits are tested but local extras
        # cannot make a broken clean checkout pass.
        tracked = subprocess.check_output(
            ["git", "ls-files", "-z", "--", str(SOURCE)], cwd=ROOT,
        ).decode().split("\0")
        self.assertTrue(any(tracked), "The SMB source files must be tracked")
        with tempfile.TemporaryDirectory(prefix="aiplayer-smb-cmake-") as temporary:
            checkout = Path(temporary) / "checkout"
            for name in filter(None, tracked):
                destination = checkout / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, destination)
            build = Path(temporary) / "build"
            for command in (
                ["cmake", "-S", str(checkout / SOURCE), "-B", str(build),
                 "-DCMAKE_BUILD_TYPE=Release"],
                ["cmake", "--build", str(build), "--config", "Release",
                 "--target", "aiplayer_smb", "--parallel", "2"],
            ):
                result = subprocess.run(
                    command, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, timeout=180,
                )
                self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
