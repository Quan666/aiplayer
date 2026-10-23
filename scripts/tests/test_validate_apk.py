"""Guard APK decoder capabilities and signing identity without Android SDK tools."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location(
    "validate_apk", Path(__file__).resolve().parents[1] / "validate_apk.py"
)
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


def native_library(abi, *, symbol="ff_pgssub_decoder", defined=True, table_type=11):
    """Small ELF with a LOAD segment, codec descriptions and real symbol entries."""
    elf_class, machine = validation.ABI_MACHINES[abi]
    wide = elf_class == 2
    data = bytearray(768)
    data[:7] = b"\x7fELF" + bytes([elf_class, 1, 1])
    struct.pack_into("<H", data, 18, machine)
    section_size, symbol_size = (64, 24) if wide else (40, 16)
    if wide:
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<Q", data, 40, 512)
        struct.pack_into("<HHHH", data, 54, 56, 1, section_size, 4)
        struct.pack_into("<I", data, 64, 1)
        struct.pack_into("<Q", data, 64 + 48, 16384)
    else:
        struct.pack_into("<I", data, 28, 52)
        struct.pack_into("<I", data, 32, 512)
        struct.pack_into("<HHHH", data, 42, 32, 1, section_size, 4)
        struct.pack_into("<I", data, 52, 1)
        struct.pack_into("<I", data, 52 + 28, 4096)
    description = b"HDMV PGS subtitle\0--enable-decoder=pgssub\0ff_pgssub_decoder\0"
    data[256:256 + len(description)] = description
    strings = b"\0" + symbol.encode() + b"\0"
    data[320:320 + len(strings)] = strings
    struct.pack_into("<I", data, 384 + symbol_size, 1)
    struct.pack_into("<H", data, 384 + symbol_size + (6 if wide else 14), 1 if defined else 0)
    section_format = "<IIQQQQIIQQ" if wide else "<IIIIIIIIII"
    for index, values in enumerate([
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (0, 1, 0, 0, 256, len(description), 0, 0, 1, 0),
        (0, 3, 0, 0, 320, len(strings), 0, 0, 1, 0),
        (0, table_type, 0, 0, 384, symbol_size * 2, 2, 0, 8, symbol_size),
    ]):
        struct.pack_into(section_format, data, 512 + index * section_size, *values)
    return bytes(data)


class ApkDecoderTest(unittest.TestCase):
    def test_defined_decoder_is_accepted_for_every_abi_and_symbol_table(self):
        for abi in validation.ABI_MACHINES:
            for table_type in (2, 11):
                with self.subTest(abi=abi, table_type=table_type):
                    validation.require_pgs_decoder(native_library(abi, table_type=table_type), abi)

    def test_descriptions_and_undefined_imports_do_not_prove_decoder_support(self):
        for abi in validation.ABI_MACHINES:
            for options in ({"symbol": "ff_subrip_decoder"}, {"defined": False}):
                with self.subTest(abi=abi, options=options):
                    with self.assertRaisesRegex(RuntimeError, "Missing PGS subtitle decoder"):
                        validation.require_pgs_decoder(native_library(abi, **options), abi)

    def test_truncated_symbol_sections_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Cannot verify PGS decoder"):
            validation.require_pgs_decoder(native_library("arm64-v8a")[:600], "truncated.so")

    def test_universal_apk_checks_each_abi_before_sdk_validation(self):
        with tempfile.TemporaryDirectory(prefix="aiplayer-apk-validation-") as directory:
            apk = Path(directory) / "fixture.apk"
            for missing_abi in validation.ABI_MACHINES:
                with self.subTest(missing_abi=missing_abi):
                    with zipfile.ZipFile(apk, "w") as archive:
                        for name in ("AndroidManifest.xml", "resources.arsc", "classes.dex"):
                            archive.writestr(name, b"fixture")
                        for abi in validation.ABI_MACHINES:
                            for library in sorted(validation.CORE_LIBRARIES):
                                archive.writestr(
                                    f"lib/{abi}/{library}",
                                    native_library(abi, defined=abi != missing_abi or library != "libmpv.so"),
                                )
                    with patch.object(validation, "sdk_tool") as sdk_tool:
                        with self.assertRaisesRegex(RuntimeError, f"Missing PGS subtitle decoder in lib/{missing_abi}/libmpv.so"):
                            validation.validate_apk(apk, abi="universal")
                        sdk_tool.assert_not_called()


class ApkCertificateTest(unittest.TestCase):
    certificate = "a592970dfc937c0ec752db77c01bf4b5bf877802dd2fe9f8cf2b40ba8fbf4f60"
    other_certificate = "b" * 64

    def test_legacy_and_build_tools_37_signer_labels(self):
        # The first four forms were captured from Build Tools 36.1/37 on the
        # same APK; the SDK-range/hybrid forms follow 37's getV3SignerName.
        for signer in (
            "Signer #1", "V1 Signer:", "V2 Signer:", "V3.0 Signer:",
            "V2 Signer #1:",
            "V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647)",
            "V3.0 Signer: (minSdkVersion=28, maxSdkVersion=32)",
            "V3.1 Signer: (minSdkVersion=33 (dev release=true), maxSdkVersion=2147483647)",
            "V3.2 Hybrid Classical Signer: (minSdkVersion=37, maxSdkVersion=2147483647)",
            "V3.2 Hybrid PQC Signer: (minSdkVersion=37, maxSdkVersion=2147483647)",
        ):
            with self.subTest(signer=signer):
                output = f"Verifies\n{signer} certificate SHA-256 digest: {self.certificate}\n"
                self.assertEqual(validation.signing_certificate_sha256(output), self.certificate)

    def test_digest_case_and_repeated_certificate_are_normalized(self):
        output = (
            f"V2 Signer: certificate SHA-256 digest: {self.certificate.upper()}\r\n"
            f"V3.0 Signer: certificate SHA-256 digest: {self.certificate}\r\n"
        )
        self.assertEqual(validation.signing_certificate_sha256(output), self.certificate)

    def test_public_keys_and_source_stamps_do_not_supply_apk_identity(self):
        unrelated = (
            f"Signer #1 public key SHA-256 digest: {self.other_certificate}\n"
            f"V3.0 Signer: public key SHA-256 digest: {self.other_certificate}\n"
            f"Source Stamp Signer: certificate SHA-256 digest: {self.other_certificate}\n"
            f"WARNING: V2 Signer: certificate SHA-256 digest: {self.other_certificate}\n"
        )
        with self.assertRaisesRegex(RuntimeError, "Cannot read APK signing certificate"):
            validation.signing_certificate_sha256(unrelated)
        self.assertEqual(
            validation.signing_certificate_sha256(
                unrelated + f"V3.0 Signer: certificate SHA-256 digest: {self.certificate}\n"
            ),
            self.certificate,
        )

    def test_distinct_signers_and_scheme_certificates_are_rejected(self):
        for signer in (
            "Signer #2", "V2 Signer #2:", "V3.0 Signer:",
            "V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647)",
            "V3.2 Hybrid PQC Signer: (minSdkVersion=37, maxSdkVersion=2147483647)",
        ):
            with self.subTest(signer=signer):
                output = (
                    f"Signer #1 certificate SHA-256 digest: {self.certificate}\n"
                    f"{signer} certificate SHA-256 digest: {self.other_certificate}\n"
                )
                with self.assertRaisesRegex(RuntimeError, "Multiple APK signing certificates"):
                    validation.signing_certificate_sha256(output)

    def test_malformed_second_signer_is_not_silently_ignored(self):
        for malformed in ("", "a" * 63, "a" * 65, "g" * 64, "AA:" * 32, self.certificate + " extra"):
            with self.subTest(digest=malformed):
                output = (
                    f"V2 Signer #1: certificate SHA-256 digest: {self.certificate}\n"
                    f"V2 Signer #2: certificate SHA-256 digest: {malformed}\n"
                )
                with self.assertRaisesRegex(RuntimeError, "Invalid APK signing certificate"):
                    validation.signing_certificate_sha256(output)

    def test_missing_certificate_is_a_parse_error(self):
        with self.assertRaisesRegex(RuntimeError, "Cannot read APK signing certificate"):
            validation.signing_certificate_sha256("Verifies\nNumber of signers: 1\n")


if __name__ == "__main__":
    unittest.main()
