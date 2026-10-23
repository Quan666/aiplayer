#!/usr/bin/env python3
"""Check the actual distributable APK, including signatures and each native ABI.

Requires Android SDK build-tools (ANDROID_SDK_ROOT, ANDROID_HOME, or the
client's local.properties). --allow-legacy-signing is only for diagnosing older
APKs; newly packaged releases must contain v1, v2 and v3 signatures.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[1]
ABI_MACHINES = {"armeabi-v7a": (1, 40), "arm64-v8a": (2, 183), "x86_64": (2, 62)}
CORE_LIBRARIES = {
    "libapp.so", "libflutter.so", "libaiplayer_smb.so", "libmpv.so",
    "libsqlite3.so", "libdartjni.so", "libmediakitandroidhelper.so",
}


def sdk_root() -> Path:
    for variable in ("ANDROID_SDK_ROOT", "ANDROID_HOME"):
        if os.environ.get(variable):
            return Path(os.environ[variable])
    properties = ROOT / "client/android/local.properties"
    if properties.exists():
        match = re.search(r"^sdk\.dir=(.+)$", properties.read_text(), re.MULTILINE)
        if match:
            return Path(match.group(1).replace(r"\:", ":").replace(r"\\", "\\"))
    raise RuntimeError("Set ANDROID_SDK_ROOT to validate APKs with Android build-tools")


def sdk_tool(name: str) -> Path:
    directory = sdk_root() / "build-tools"
    versions = sorted(
        (p for p in directory.iterdir() if p.is_dir()),
        key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)),
        reverse=True,
    )
    suffixes = [".bat", ".exe", ""] if os.name == "nt" else [""]
    for version in versions:
        for suffix in suffixes:
            path = version / (name + suffix)
            if path.is_file():
                return path
    raise RuntimeError(f"Android build-tools does not contain {name}")


def run(command: list[str]) -> str:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed: {result.stdout.strip()}")
    return result.stdout


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def signing_certificate_sha256(signature_output: str) -> str:
    """Read the APK signer identity from old and Build Tools 37 apksigner output."""
    # Build Tools 37 replaced "Signer #1" with scheme names, such as
    # "V3.0 Signer:". Rotation/hybrid signers also include their SDK range.
    # Match certificate lines only; a public key or Source Stamp is not the
    # certificate used to sign the APK.
    signer = (
        r"(?:Signer #[1-9][0-9]*|"
        r"(?:V[12]|V3\.[01]|V3\.2 Hybrid (?:Classical|PQC)) Signer(?: #[1-9][0-9]*)?:"
        r"(?: \(minSdkVersion=[0-9]+(?: \(dev release=true\))?, maxSdkVersion=[0-9]+\))?)"
    )
    certificates = set()
    for line in signature_output.splitlines():
        match = re.fullmatch(signer + r" certificate SHA-256 digest:[ \t]*(.*)", line)
        if not match:
            continue
        fingerprint = match.group(1).strip()
        if not re.fullmatch(r"[0-9a-fA-F]{64}", fingerprint):
            raise RuntimeError("Invalid APK signing certificate SHA-256 in apksigner output")
        certificates.add(fingerprint.lower())
    if not certificates:
        raise RuntimeError("Cannot read APK signing certificate SHA-256 from apksigner output")
    if len(certificates) != 1:
        raise RuntimeError("Multiple APK signing certificates reported by apksigner; refusing ambiguous signing identity")
    return certificates.pop()


def elf_alignment(data: bytes, abi: str, name: str) -> list[int]:
    if data[:4] != b"\x7fELF" or data[5] not in (1, 2):
        raise RuntimeError(f"Invalid ELF library: {name}")
    endian = "<" if data[5] == 1 else ">"
    elf_class = data[4]
    machine = struct.unpack_from(endian + "H", data, 18)[0]
    if (elf_class, machine) != ABI_MACHINES[abi]:
        raise RuntimeError(f"Wrong ELF architecture inside {name}")
    if elf_class == 2:
        offset = struct.unpack_from(endian + "Q", data, 32)[0]
        size, count = struct.unpack_from(endian + "HH", data, 54)
    else:
        offset = struct.unpack_from(endian + "I", data, 28)[0]
        size, count = struct.unpack_from(endian + "HH", data, 42)
    alignments = []
    for index in range(count):
        header = offset + index * size
        if struct.unpack_from(endian + "I", data, header)[0] == 1:
            alignments.append(struct.unpack_from(endian + ("Q" if elf_class == 2 else "I"), data, header + (48 if elf_class == 2 else 28))[0])
    if not alignments:
        raise RuntimeError(f"No ELF LOAD segments in {name}")
    if elf_class == 2 and any(alignment < 16384 for alignment in alignments):
        raise RuntimeError(f"64-bit library lacks 16 KB ELF alignment: {name}")
    return alignments


def require_pgs_decoder(data: bytes, name: str) -> None:
    """Require the decoder implementation, not FFmpeg's always-present codec name.

    Android's packaged libmpv exports FFmpeg decoder objects in .dynsym, which
    survives stripping. Also accept .symtab when validating an unstripped build.
    An undefined import or a codec description string is not decoder evidence.
    """
    symbol_name = b"ff_pgssub_decoder"
    try:
        if data[:4] != b"\x7fELF" or data[4] not in (1, 2) or data[5] not in (1, 2):
            raise ValueError("invalid ELF header")
        endian = "<" if data[5] == 1 else ">"
        wide = data[4] == 2
        section_format = endian + ("IIQQQQIIQQ" if wide else "IIIIIIIIII")
        section_offset = struct.unpack_from(endian + ("Q" if wide else "I"), data, 40 if wide else 32)[0]
        section_size, section_count = struct.unpack_from(endian + "HH", data, 58 if wide else 46)
        if section_offset:
            if section_size < struct.calcsize(section_format):
                raise ValueError("invalid ELF section size")
            if section_count == 0:  # Extended ELF section count lives in section zero.
                section_count = struct.unpack_from(section_format, data, section_offset)[5]
            if section_offset + section_size * section_count > len(data):
                raise ValueError("truncated ELF sections")
            sections = [struct.unpack_from(section_format, data, section_offset + index * section_size)
                        for index in range(section_count)]
            for section in sections:
                if section[1] not in (2, 11):  # SHT_SYMTAB, SHT_DYNSYM
                    continue
                offset, length, strings_index, stride = section[4], section[5], section[6], section[9]
                if strings_index >= len(sections) or stride < (24 if wide else 16) or length % stride:
                    raise ValueError("invalid ELF symbol table")
                strings_section = sections[strings_index]
                strings_offset, strings_length = strings_section[4], strings_section[5]
                if strings_section[1] != 3 or offset + length > len(data) or strings_offset + strings_length > len(data):
                    raise ValueError("invalid ELF symbol strings")
                for position in range(offset, offset + length, stride):
                    name_offset = struct.unpack_from(endian + "I", data, position)[0]
                    defined_section = struct.unpack_from(endian + "H", data, position + (6 if wide else 14))[0]
                    if defined_section == 0 or name_offset + len(symbol_name) + 1 > strings_length:
                        continue
                    start = strings_offset + name_offset
                    if data[start:start + len(symbol_name) + 1] == symbol_name + b"\0":
                        return
    except (IndexError, ValueError, struct.error) as error:
        raise RuntimeError(f"Cannot verify PGS decoder in {name}: {error}") from error
    raise RuntimeError(f"Missing PGS subtitle decoder in {name}: no defined ff_pgssub_decoder symbol")


def validate_apk(path: Path, *, abi: str = "auto", expected_version: str | None = None, require_all_signatures: bool = True) -> dict:
    path = path.resolve()
    native = {}
    with zipfile.ZipFile(path) as archive:
        entries = archive.namelist()
        duplicates = [name for name, count in Counter(entries).items() if count > 1]
        if duplicates:
            raise RuntimeError(f"Duplicate ZIP entries: {duplicates}")
        invalid = archive.testzip()
        if invalid:
            raise RuntimeError(f"APK CRC check failed: {invalid}")
        for required in ("AndroidManifest.xml", "resources.arsc", "classes.dex"):
            if required not in entries:
                raise RuntimeError(f"APK is missing {required}")
        for name in entries:
            if name.startswith("lib/") and name.endswith(".so"):
                parts = Path(name).parts
                if len(parts) != 3 or parts[1] not in ABI_MACHINES:
                    raise RuntimeError(f"Unexpected native library path: {name}")
                data = archive.read(name)
                library = {
                    "elf_load_alignment": elf_alignment(data, parts[1], name),
                    "uncompressed": archive.getinfo(name).compress_type == zipfile.ZIP_STORED,
                }
                if parts[2] == "libmpv.so":
                    require_pgs_decoder(data, name)
                    library["pgs_decoder_symbol"] = "ff_pgssub_decoder"
                native.setdefault(parts[1], {})[parts[2]] = library
        expected_abis = sorted(ABI_MACHINES) if abi == "universal" else (["arm64-v8a"] if abi == "arm64" else sorted(native))
        if not native or sorted(native) != expected_abis:
            raise RuntimeError(f"Expected ABIs {expected_abis}, found {sorted(native)}")
        for architecture, libraries in native.items():
            missing = CORE_LIBRARIES.difference(libraries)
            if missing:
                raise RuntimeError(f"Incomplete {architecture} playback libraries: {sorted(missing)}")
    badging = run([str(sdk_tool("aapt")), "dump", "badging", str(path)])
    match = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    if not match or match.group(1) != "app.aiplayer.aiplayer":
        raise RuntimeError("Unexpected or unreadable Android package manifest")
    package, version_code, version_name = match.groups()
    minimum = int(re.search(r"sdkVersion:'(\d+)'", badging).group(1))
    target = int(re.search(r"targetSdkVersion:'(\d+)'", badging).group(1))
    if minimum != 24:
        raise RuntimeError(f"Unexpected minimum SDK {minimum}; this release promises Android 7+")
    if "application-debuggable" in badging:
        raise RuntimeError("Refusing to publish a debuggable APK as release")
    if "launchable-activity: name='app.aiplayer.aiplayer.MainActivity'" not in badging:
        raise RuntimeError("APK has no expected launcher activity")
    if expected_version:
        expected_name, _, expected_code = expected_version.partition("+")
        if version_name != expected_name or (expected_code and version_code != expected_code):
            raise RuntimeError(f"Stale APK version {version_name}+{version_code}; expected {expected_version}")
    signature_command = [str(sdk_tool("apksigner")), "verify", "--verbose", "--print-certs"]
    if require_all_signatures:
        # APK minSdk 24 normally makes apksigner skip JAR verification and
        # report v1:false even when present. API 23 forces the v1 check too;
        # this checks signature compatibility, not Android 6 app support.
        signature_command += ["--min-sdk-version", "23"]
    signature_output = run([*signature_command, str(path)])
    signatures = {}
    for scheme in ("v1", "v2", "v3"):
        signatures[scheme] = bool(re.search(rf"Verified using {scheme} scheme .*: true", signature_output))
    if require_all_signatures and not all(signatures.values()):
        raise RuntimeError(f"Installer compatibility signing requires v1 + v2 + v3: {signatures}")
    if not signatures["v2"]:
        raise RuntimeError("APK must have a valid v2 signature for Android 7+")
    certificate = signing_certificate_sha256(signature_output)
    run([str(sdk_tool("zipalign")), "-c", "-P", "16", "4", str(path)])
    return {
        "file_name": path.name, "size_bytes": path.stat().st_size, "sha256": digest(path),
        "package": package, "version_name": version_name, "version_code": int(version_code),
        "min_sdk": minimum, "target_sdk": target, "abis": sorted(native),
        "signature_schemes": signatures,
        "certificate_sha256": certificate,
        "zip_crc_valid": True, "zip_alignment_16kb": True, "native_libraries": native,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--abi", choices=["auto", "universal", "arm64"], default="auto")
    parser.add_argument("--expected-version")
    parser.add_argument("--allow-legacy-signing", action="store_true")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    report = validate_apk(arguments.apk, abi=arguments.abi, expected_version=arguments.expected_version, require_all_signatures=not arguments.allow_legacy_signing)
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
