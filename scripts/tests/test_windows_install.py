"""Exercise Windows bundle installation without a Flutter or Windows SDK build."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("cmake"), "CMake is required")
class WindowsInstallTest(unittest.TestCase):
    def test_runtime_libraries_install_into_the_bundle(self):
        # Use the actual application install rules with tiny Flutter/runner
        # stand-ins. Inject a runtime DLL so a Linux test exercises the same
        # InstallRequiredSystemLibraries rule that MSVC enables on Windows.
        with tempfile.TemporaryDirectory(prefix="aiplayer-windows-install-") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            shutil.copyfile(ROOT / "client/windows/CMakeLists.txt", source / "CMakeLists.txt")
            flutter = source / "flutter"
            flutter.mkdir()
            runner = source / "runner"
            runner.mkdir()
            assets = source / "assets"
            (assets / "native_assets/windows").mkdir(parents=True)
            (assets / "flutter_assets").mkdir()
            files = (
                "aiplayer_test_runtime.dll", "flutter_windows.dll", "icudtl.dat", "app.so",
                "flutter_assets/AssetManifest.bin",
            )
            for name in files:
                (assets / name).write_text(f"fixture for {name}\n")
            (flutter / "CMakeLists.txt").write_text(
                'set(FLUTTER_LIBRARY "${CMAKE_SOURCE_DIR}/assets/flutter_windows.dll" PARENT_SCOPE)\n'
                'set(FLUTTER_ICU_DATA_FILE "${CMAKE_SOURCE_DIR}/assets/icudtl.dat" PARENT_SCOPE)\n'
                'set(PROJECT_BUILD_DIR "${CMAKE_SOURCE_DIR}/assets/" PARENT_SCOPE)\n'
                'set(AOT_LIBRARY "${CMAKE_SOURCE_DIR}/assets/app.so" PARENT_SCOPE)\n'
            )
            (flutter / "generated_plugins.cmake").write_text("set(PLUGIN_BUNDLED_LIBRARIES)\n")
            (runner / "CMakeLists.txt").write_text(
                "add_executable(aiplayer main.cc)\n"
                'file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/runner-dir-$<CONFIG>.txt"\n'
                '  CONTENT "$<TARGET_FILE_DIR:aiplayer>")\n'
            )
            (runner / "main.cc").write_text("int main() { return 0; }\n")
            build = root / "build"
            for command in (
                ["cmake", "-S", str(source), "-B", str(build),
                 "-DCMAKE_BUILD_TYPE=Release",
                 f"-DCMAKE_INSTALL_SYSTEM_RUNTIME_LIBS={(assets / 'aiplayer_test_runtime.dll').as_posix()}"],
                ["cmake", "--build", str(build), "--config", "Release"],
                ["cmake", "--install", str(build), "--config", "Release"],
            ):
                result = subprocess.run(
                    command, cwd=root, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT, timeout=120,
                )
                self.assertEqual(result.returncode, 0, result.stdout)
            bundle = Path((build / "runner-dir-Release.txt").read_text())
            for name in files:
                destination = bundle / name if name.endswith(".dll") else bundle / "data" / name
                with self.subTest(file=name):
                    self.assertTrue(destination.is_file(), f"Missing bundled file: {destination}")
                    self.assertEqual(destination.read_text(), (assets / name).read_text())


if __name__ == "__main__":
    unittest.main()
