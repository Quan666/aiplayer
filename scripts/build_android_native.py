#!/usr/bin/env python3
"""Build Android libmpv from hash-locked upstream sources, without signing keys.

Requires Linux, Python 3.12+, NDK r28c, cmake, meson, ninja, make, pkg-config,
autoconf/automake/libtool and nasm. No package manager is run by this recipe.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'packages/media_kit_libs_android_video/native'
LOCK = NATIVE / 'sources.lock.json'
ABIS = {
    'arm64-v8a': ('aarch64-linux-android', 'aarch64', 'armv8-a'),
    'armeabi-v7a': ('armv7a-linux-androideabi', 'arm', 'armv7-a'),
    'x86': ('i686-linux-android', 'x86', 'i686'),
    'x86_64': ('x86_64-linux-android', 'x86_64', 'generic'),
}
SUPPORTED_APIS = (23, 24)


def selected_api(requested: int | None, default: int, environment: dict) -> int:
    """Keep an explicit Android 6 target separate from the default source pin."""
    value = requested if requested is not None else environment.get('AIPLAYER_ANDROID_MIN_SDK', default)
    try:
        api = int(value)
    except (TypeError, ValueError):
        raise ValueError('Android native API must be 23 or 24') from None
    if api not in SUPPORTED_APIS:
        raise ValueError('Android native API must be 23 or 24')
    return api


def build_fingerprint(lock_bytes: bytes, recipe_bytes: bytes, api: int) -> str:
    return hashlib.sha256(lock_bytes + recipe_bytes + f'\0api={api}'.encode()).hexdigest()


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download(source: dict, cache: Path) -> Path:
    """An existing cache is trusted only after hashing it again."""
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / source['archive']
    if target.is_file() and digest(target) == source['sha256']:
        return target
    if not source['url'].startswith('https://'):
        raise RuntimeError('Native sources require HTTPS')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=cache, suffix='.part', delete=False) as out:
            temporary = Path(out.name)
            request = urllib.request.Request(source['url'], headers={'User-Agent': 'AIPlayer-native-build'})
            with urllib.request.urlopen(request, timeout=90) as response:
                if not response.url.startswith('https://'):
                    raise RuntimeError('Native source redirected outside HTTPS')
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > 128 * 1024 * 1024:
                        raise RuntimeError('Native source exceeds size limit')
                    out.write(chunk)
        if digest(temporary) != source['sha256']:
            raise RuntimeError(f"SHA-256 mismatch for {source['name']}")
        temporary.replace(target)
        return target
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def extract(archive: Path, destination: Path) -> None:
    if destination.exists() or destination.is_symlink():
        raise RuntimeError(f'Extract destination must be fresh: {destination}')
    temporary = destination.with_name(destination.name + '.extract')
    shutil.rmtree(temporary, ignore_errors=True)
    temporary.mkdir(parents=True)
    try:
        with tarfile.open(archive) as source:
            # Python's data filter rejects traversal, escaping links and devices.
            source.extractall(temporary, filter='data')
        children = list(temporary.iterdir())
        if len(children) != 1 or not children[0].is_dir():
            raise RuntimeError(f'Unexpected archive layout: {archive.name}')
        children[0].rename(destination)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def run(command: list[str | Path], *, cwd: Path, env: dict) -> None:
    print('+', ' '.join(str(value) for value in command), flush=True)
    subprocess.run([str(value) for value in command], cwd=cwd, env=env, check=True)


def apply_compat_patch(source: Path, patch: Path, env: dict) -> None:
    """Use patch directly: git apply can silently skip files beneath a parent repo."""
    command = ['patch', '--batch', '--fuzz=0', '-p1', '-i', str(patch)]
    result = subprocess.run([*command, '--forward', '--dry-run'], cwd=source,
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode == 0:
        run([*command, '--forward'], cwd=source, env=env)
    else:
        # A compatibility fix may already be present in the locked maintenance source.
        # Context drift or a partial patch must fail this reverse check as well.
        run([*command, '--reverse', '--dry-run'], cwd=source, env=env)


def isolated_environment(base: dict, work: Path) -> dict:
    # Upstream version probes must not discover the application's parent .git.
    environment = {key: value for key, value in base.items() if not key.startswith('GIT_')}
    environment.update(GIT_CEILING_DIRECTORIES=str(work.resolve()),
                       GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    return environment


def build(args: argparse.Namespace) -> None:
    lock_bytes = LOCK.read_bytes()
    recipe_bytes = Path(__file__).read_bytes()
    lock_digest = hashlib.sha256(lock_bytes).hexdigest()
    recipe_digest = hashlib.sha256(recipe_bytes).hexdigest()
    lock = json.loads(lock_bytes)
    api = selected_api(args.api, lock['api'], os.environ)
    ndk = Path(args.ndk or os.environ.get('ANDROID_NDK_HOME') or os.environ.get('ANDROID_NDK_ROOT') or
               ROOT / '.local-build/sdk/android/ndk' / lock['ndk']).resolve()
    properties = (ndk / 'source.properties').read_text()
    if f'Pkg.Revision = {lock["ndk"]}' not in properties:
        raise RuntimeError(f"Use the locked Android NDK {lock['ndk']}")
    toolchain = ndk / 'toolchains/llvm/prebuilt/linux-x86_64'
    if not toolchain.is_dir():
        raise RuntimeError('The native build currently requires Linux x86_64')
    patch_bytes = {}
    for patch, expected in lock['patches'].items():
        patch_bytes[patch] = (NATIVE / 'patches' / patch).read_bytes()
        if hashlib.sha256(patch_bytes[patch]).hexdigest() != expected:
            raise RuntimeError(f'Native patch hash mismatch: {patch}')
    fingerprint = build_fingerprint(lock_bytes, recipe_bytes, api)
    work = Path(args.work_dir).resolve() / fingerprint[:16] / args.abi
    # Never restore compiled objects or extracted source from an unauthenticated cache.
    if work.is_symlink() or work.parent.is_symlink():
        raise RuntimeError('Native work directory must not be a symlink')
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    patch_directory = work / 'patches'
    patch_directory.mkdir()
    for name, contents in patch_bytes.items():
        (patch_directory / name).write_bytes(contents)
    prefix = work / 'prefix'
    prefix.mkdir(exist_ok=True)
    sources = work / 'sources'
    sources.mkdir(exist_ok=True)
    for source in lock['sources']:
        archive = download(source, Path(args.cache_dir).resolve())
        extract(archive, sources / source['name'])
    framework = sources / 'mbedtls/framework'
    if framework.exists():
        shutil.rmtree(framework)
    framework.symlink_to('../mbedtls-framework', target_is_directory=True)
    # Archive builds have no VCS checkout: use the source lock for their release identifiers.
    for name in ['ffmpeg', 'mpv']:
        version = next(source['version'] for source in lock['sources'] if source['name'] == name)
        (sources / name / 'VERSION').write_text(version + '\n')
    triple, architecture, cpu = ABIS[args.abi]
    compiler = str(toolchain / 'bin' / f'{triple}{api}-clang')
    cpp = compiler + '++'
    flags = '-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2'
    linkflags = '-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-z,relro,-z,now'
    env = isolated_environment(os.environ, work)
    for key in ['CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'LIBRARY_PATH', 'PKG_CONFIG_PATH']:
        env.pop(key, None)
    env.update(PATH=str(toolchain / 'bin') + os.pathsep + env['PATH'],
               CC=compiler, CXX=cpp, AR='llvm-ar', RANLIB='llvm-ranlib', STRIP='llvm-strip',
               CFLAGS=flags, CXXFLAGS=flags, LDFLAGS=linkflags,
               PKG_CONFIG_LIBDIR=str(prefix / 'lib/pkgconfig'), PKG_CONFIG_SYSROOT_DIR='',
               SOURCE_DATE_EPOCH='0')
    cross = work / 'cross.ini'
    cross.write_text(f"""[binaries]
c = '{compiler}'
cpp = '{cpp}'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '{architecture}'
cpu = '{cpu}'
endian = 'little'
[built-in options]
buildtype = 'release'
default_library = 'static'
wrap_mode = 'nodownload'
c_args = ['-fPIC', '-fstack-protector-strong']
cpp_args = ['-fPIC', '-fstack-protector-strong']
c_link_args = ['-Wl,-z,max-page-size=16384', '-Wl,-z,common-page-size=16384', '-Wl,-z,relro,-z,now']
cpp_link_args = ['-Wl,-z,max-page-size=16384', '-Wl,-z,common-page-size=16384', '-Wl,-z,relro,-z,now']
""")
    # zlib is supplied by Android itself; never discover a host zlib through pkg-config.
    (prefix / 'lib/pkgconfig').mkdir(parents=True)
    (prefix / 'lib/pkgconfig/zlib.pc').write_text('Name: zlib\nDescription: Android system zlib\nVersion: 1.2.8\nLibs: -lz\n')
    def execute(command, cwd=work):
        run(command, cwd=cwd, env=env)
    def stage(name, callback):
        print(f'Building {name} for {args.abi}, Android API {api}', flush=True)
        callback()
    def cmake(name, options=(), subpath=''):
        src = sources / name / subpath
        out = work / ('build-' + name)
        execute(['cmake', '-S', src, '-B', out, '-G', 'Ninja',
                 '-DCMAKE_TOOLCHAIN_FILE=' + str(ndk / 'build/cmake/android.toolchain.cmake'),
                 '-DANDROID_ABI=' + args.abi, '-DANDROID_PLATFORM=android-' + str(api),
                 '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
                 '-DCMAKE_INSTALL_PREFIX=' + str(prefix), '-DCMAKE_INSTALL_LIBDIR=lib',
                 '-DBUILD_SHARED_LIBS=OFF', '-DANDROID_STL=c++_static', *options])
        execute(['cmake', '--build', out, '--parallel', str(args.jobs)])
        execute(['cmake', '--install', out])
    def meson(name, options):
        out = work / ('build-' + name)
        execute(['meson', 'setup', out, sources / name, '--cross-file', cross,
                 '--prefix', prefix, '--libdir', 'lib', *options])
        execute(['ninja', '-C', out, '-j', str(args.jobs)])
        execute(['ninja', '-C', out, 'install'])
    def autoconf(name, options):
        src = sources / name
        out = work / ('build-' + name)
        out.mkdir(exist_ok=True)
        execute([src / 'configure', '--host=' + triple.replace('armv7a-', 'arm-'),
                 '--prefix=' + str(prefix), '--enable-static', '--disable-shared', *options], cwd=out)
        execute(['make', '-j', str(args.jobs)], cwd=out)
        execute(['make', 'install'], cwd=out)

    stage('mbedtls', lambda: cmake('mbedtls', ['-DENABLE_PROGRAMS=OFF', '-DENABLE_TESTING=OFF',
                                               '-DUSE_SHARED_MBEDTLS_LIBRARY=OFF']))
    # FFmpeg 6.1's pkg-config probe expects this file (Mbed TLS' CMake doesn't install it).
    (prefix / 'lib/pkgconfig/mbedtls.pc').write_text(f'''prefix={prefix}
libdir=${{prefix}}/lib
includedir=${{prefix}}/include
Name: mbedtls
Description: Mbed TLS
Version: {next(s['version'] for s in lock['sources'] if s['name'] == 'mbedtls')}
Libs: -L${{libdir}} -lmbedtls -lmbedx509 -lmbedcrypto
Cflags: -I${{includedir}}
''')
    stage('dav1d', lambda: meson('dav1d', ['-Denable_tests=false', '-Denable_tools=false']))
    stage('libxml2', lambda: cmake('libxml2', ['-DLIBXML2_WITH_PYTHON=OFF', '-DLIBXML2_WITH_PROGRAMS=OFF',
                       '-DLIBXML2_WITH_TESTS=OFF', '-DLIBXML2_WITH_LZMA=OFF', '-DLIBXML2_WITH_ICONV=OFF']))
    stage('freetype', lambda: cmake('freetype', ['-DFT_DISABLE_HARFBUZZ=TRUE', '-DFT_DISABLE_BROTLI=TRUE',
                                              '-DFT_DISABLE_BZIP2=TRUE', '-DFT_DISABLE_PNG=TRUE']))
    stage('fribidi', lambda: meson('fribidi', ['-Dtests=false', '-Ddocs=false']))
    stage('harfbuzz', lambda: meson('harfbuzz', ['-Dtests=disabled', '-Ddocs=disabled', '-Dutilities=disabled',
              '-Dglib=disabled', '-Dgobject=disabled', '-Dcairo=disabled', '-Dicu=disabled', '-Dgraphite2=disabled',
              '-Dfreetype=enabled']))
    stage('libass', lambda: autoconf('libass', ['--with-pic', '--disable-require-system-font-provider']))

    def build_ffmpeg():
        src = sources / 'ffmpeg'
        for name in ['ffmpeg-dash.patch', 'ffmpeg-hls-seek.patch']:
            # These media-kit compatibility fixes may already exist in the maintenance source.
            apply_compat_patch(src, patch_directory / name, env)
        out = work / 'build-ffmpeg'
        out.mkdir(exist_ok=True)
        # Match the upstream ABI exceptions: 32-bit x86 NASM objects are not PIC-safe.
        abi_options = ['--disable-asm'] if args.abi == 'x86' else []
        codec_cflags = flags + ' -I' + str(prefix / 'include')
        if args.abi == 'armeabi-v7a':
            codec_cflags += ' -mfpu=neon -mcpu=cortex-a8'
        execute([src / 'configure', '--prefix=' + str(prefix), '--target-os=android', '--enable-cross-compile',
                 '--cc=' + compiler, '--cxx=' + cpp, '--ar=llvm-ar', '--nm=llvm-nm', '--ranlib=llvm-ranlib',
                 '--arch=' + ('arm' if architecture == 'arm' else architecture), '--cpu=' + cpu,
                 '--pkg-config=pkg-config', '--pkg-config-flags=--static', '--enable-pic', '--disable-autodetect',
                 '--extra-cflags=' + codec_cflags, *abi_options,
                 '--extra-ldflags=' + linkflags + ' -L' + str(prefix / 'lib'),
                 '--disable-gpl', '--disable-nonfree', '--enable-version3', '--enable-static', '--disable-shared',
                 '--enable-decoders', '--enable-demuxers', '--enable-parsers', '--disable-muxers',
                 '--disable-encoders', '--disable-protocols', '--disable-devices', '--disable-filters',
                 '--disable-doc', '--disable-avdevice', '--disable-postproc', '--disable-programs',
                 '--enable-jni', '--enable-mediacodec', '--enable-mbedtls', '--enable-libdav1d', '--enable-libxml2',
                 '--enable-zlib', '--enable-filter=overlay,equalizer',
                 '--enable-encoder=mjpeg,ljpeg,jpegls,jpeg2000,png',
                 '--enable-protocol=async,cache,crypto,data,ffrtmphttp,file,ftp,hls,http,httpproxy,https,pipe,rtmp,rtmps,rtmpt,rtmpts,rtp,subfile,tcp,tls,srt',
                 '--disable-stripping'], cwd=out)
        execute(['make', '-j', str(args.jobs)], cwd=out)
        execute(['make', 'install'], cwd=out)
    stage('ffmpeg', build_ffmpeg)

    def build_mpv():
        apply_compat_patch(sources / 'mpv', patch_directory / 'mpv-jni.patch', env)
        meson('mpv', ['--prefer-static', '--default-library=shared', '-Dgpl=false', '-Dlibmpv=true',
                      '-Dlua=disabled', '-Dcplayer=false', '-Diconv=disabled', '-Dvulkan=disabled',
                      '-Dlibplacebo=disabled', '-Dmanpage-build=disabled'])
    stage('mpv', build_mpv)
    stage('helper', lambda: cmake('helper', subpath='app/src/main/cpp'))
    helper = work / 'build-helper/libmediakitandroidhelper.so'
    libraries = {'libmpv.so': prefix / 'lib/libmpv.so', 'libmediakitandroidhelper.so': helper}
    system_libraries = {'libc.so', 'libm.so', 'libdl.so', 'liblog.so', 'libandroid.so', 'libz.so',
                        'libEGL.so', 'libGLESv2.so', 'libGLESv3.so', 'libOpenSLES.so', 'libmediandk.so'}
    expected_machine = {'arm64-v8a': 183, 'armeabi-v7a': 40, 'x86': 3, 'x86_64': 62}[args.abi]
    def inspect_library(name, library):
        with library.open('rb') as stream:
            header = stream.read(20)
        expected_class = 2 if args.abi in {'arm64-v8a', 'x86_64'} else 1
        if (header[:4] != b'\x7fELF' or header[4] != expected_class or header[5] != 1 or
                struct.unpack_from('<H', header, 18)[0] != expected_machine):
            raise RuntimeError(f'Wrong native ABI in {name}: expected {args.abi}')
        headers = subprocess.check_output([toolchain / 'bin/llvm-readelf', '-lW', library], text=True)
        loads = [line for line in headers.splitlines() if line.strip().startswith('LOAD ')]
        if not loads or any(int(line.split()[-1], 16) < 16384 for line in loads):
            raise RuntimeError(f'{name} does not support 16 KB pages')
        dynamic = subprocess.check_output([toolchain / 'bin/llvm-readelf', '-dW', library], text=True)
        return set(re.findall(r'Shared library: \[([^\]]+)\]', dynamic))
    dependencies = {name: inspect_library(name, library) for name, library in libraries.items()}
    if any('libc++_shared.so' in needed for needed in dependencies.values()):
        system_triple = triple.replace('armv7a-', 'arm-')
        runtime = toolchain / 'sysroot/usr/lib' / system_triple / 'libc++_shared.so'
        libraries['libc++_shared.so'] = runtime
        dependencies['libc++_shared.so'] = inspect_library('libc++_shared.so', runtime)
    for name, needed in dependencies.items():
        missing = needed - system_libraries - libraries.keys()
        if missing:
            raise RuntimeError(f'Unbundled dependencies in {name}: {sorted(missing)}')
    # Keep symbols needed by capability validation while omitting large debug sections.
    # Copy first so an optional NDK runtime is never modified in place.
    staged = work / 'staged-libraries'
    staged.mkdir()
    for name, library in libraries.copy().items():
        target = staged / name
        shutil.copyfile(library, target)
        execute([toolchain / 'bin/llvm-strip', '--strip-debug', target])
        inspect_library(name, target)
        libraries[name] = target
    symbols = subprocess.check_output([toolchain / 'bin/llvm-readelf', '-sW', libraries['libmpv.so']], text=True)
    for symbol in ['ff_pgssub_decoder', 'mpv_lavc_set_java_vm', 'ff_h264_mediacodec_decoder']:
        if not any(symbol in line and ' UND ' not in line for line in symbols.splitlines()):
            raise RuntimeError(f'Missing native playback capability: {symbol}')
    if digest(LOCK) != lock_digest or digest(Path(__file__)) != recipe_digest:
        raise RuntimeError('Native source lock or build recipe changed during compilation')
    args.output.mkdir(parents=True, exist_ok=True)
    jar = args.output / f'full-{args.abi}.jar'
    metadata_path = args.output / f'full-{args.abi}.json'
    if jar.is_symlink() or metadata_path.is_symlink():
        raise RuntimeError('Native output must not contain symlinks')
    with zipfile.ZipFile(jar, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for name, library in sorted(libraries.items()):
            entry = zipfile.ZipInfo(f'lib/{args.abi}/{name}', date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(entry, library.read_bytes())
    metadata = dict(abi=args.abi, api=api, sha256=digest(jar), sourcesLockSha256=lock_digest,
                    recipeSha256=recipe_digest, sources=lock['sources'])
    metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Built {jar} ({metadata["sha256"]})', flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--abi', required=True, choices=ABIS)
    parser.add_argument('--api', type=int, choices=SUPPORTED_APIS,
                        help='Minimum Android API; defaults to AIPLAYER_ANDROID_MIN_SDK or the source lock (24)')
    parser.add_argument('--output', type=Path,
                        help='Artifact directory; API 23 defaults to artifacts-api23, API 24 to artifacts')
    parser.add_argument('--ndk', default=None)
    parser.add_argument('--work-dir', default=ROOT / '.local-build/native-player/build')
    parser.add_argument('--cache-dir', default=ROOT / '.local-build/native-player/sources')
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 16:
        parser.error('--jobs must be between 1 and 16')
    try:
        args.api = selected_api(args.api, json.loads(LOCK.read_text())['api'], os.environ)
    except ValueError as error:
        parser.error(str(error))
    if args.output is None:
        name = 'artifacts-api23' if args.api == 23 else 'artifacts'
        args.output = ROOT / '.local-build/native-player' / name
    build(args)


if __name__ == '__main__':
    main()
