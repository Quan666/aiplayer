"""Catch Apple native source/configuration errors before the expensive Xcode builds."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


PLUGIN = Path(__file__).resolve().parents[2] / "packages/aiplayer_smb"
INCLUDE = PLUGIN / "src/vendor/libsmb2/include"


class SmbModuleMapTest(unittest.TestCase):
    def test_declared_headers_exist(self):
        headers = re.findall(r'\bheader\s+"([^"]+)"', (INCLUDE / "module.modulemap").read_text())
        self.assertTrue(headers, "Module map must declare headers")
        for header in headers:
            with self.subTest(header=header):
                self.assertTrue((INCLUDE / header).is_file(), f"Missing module header: {header}")

    @unittest.skipUnless(shutil.which("clang"), "Clang is needed to exercise module loading")
    def test_apple_native_sources_compile_with_modules(self):
        # Exercise every source matched by the CocoaPods source_files glob with
        # their shared config and module map. A fresh cache forces module loading.
        # This catches missing private headers, missing build definitions and
        # module import cycles on Linux too; it is not an Apple SDK build.
        for platform in ("ios", "macos"):
            with tempfile.TemporaryDirectory(prefix="aiplayer-clang-") as cache:
                sources = sorted((PLUGIN / platform / "Classes").rglob("*.c"))
                self.assertTrue(sources, f"No native sources found for {platform}")
                for source in sources:
                    with self.subTest(platform=platform, source=source.name):
                        result = subprocess.run(
                            ["clang", "-fsyntax-only", "-fmodules", "-fimplicit-module-maps",
                             f"-fmodules-cache-path={cache}", "-DHAVE_CONFIG_H=1",
                             f"-I{PLUGIN / 'src/apple'}", f"-I{INCLUDE}", f"-I{INCLUDE / 'smb2'}",
                             str(source)],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
