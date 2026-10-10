#!/usr/bin/env python3
"""Prepare pinned, self-contained macOS arm64 media tools for the app and CLI."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / 'build/media-sources'
OUTPUT = ROOT / 'build/media-tools'
VERSIONS = {'yt-dlp': '2026.08.19', 'quickjs': '0.17.0', 'ffmpeg': '8.0.1', 'recipe': 4}
FFMPEG_LIBRARIES = ['libavcodec.62.dylib', 'libavfilter.11.dylib', 'libavformat.62.dylib',
                    'libavutil.60.dylib', 'libswresample.6.dylib', 'libswscale.9.dylib']
BINARIES = ['yt-dlp', 'qjs', 'ffmpeg', 'ffprobe', *FFMPEG_LIBRARIES]
ASSETS = [
    ('yt-dlp.zip', 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos.zip',
     '07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8'),
    ('quickjs-0.17.0.tar.gz', 'https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz',
     '559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9'),
    ('ffmpeg-8.0.1.tar.xz', 'https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz',
     '05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41'),
]


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def fetch(asset):
    name, url, checksum = asset
    path = CACHE / name
    if path.exists() and digest(path) == checksum:
        return path
    temporary = path.with_suffix(path.suffix + '.partial')
    print('Downloading', name, flush=True)
    with urllib.request.urlopen(url, timeout=60) as response, temporary.open('wb') as handle:
        shutil.copyfileobj(response, handle)
    if digest(temporary) != checksum:
        temporary.unlink()
        raise RuntimeError('Checksum mismatch: ' + name)
    temporary.replace(path)
    return path


def inventory(folder):
    return {str(path.relative_to(folder)): ('link:' + os.readlink(path) if path.is_symlink() else digest(path))
            for path in sorted(folder.rglob('*'))
            if path.name != 'versions.json' and (path.is_file() or path.is_symlink())}


def sign(path, private_libraries=False):
    entitlements = ['--entitlements', str(ROOT / 'Resources/Downloader.entitlements')] if private_libraries else []
    subprocess.run(['codesign', '--force', '--options', 'runtime', *entitlements,
                    '--timestamp=none', '--sign', '-', str(path)], check=True)


def prepare(output):
    with zipfile.ZipFile(CACHE / 'yt-dlp.zip') as archive:
        archive.extractall(output)
    (output / 'yt-dlp_macos').rename(output / 'yt-dlp')
    # The upstream ZIP expands framework symlinks into four identical Python
    # binaries. Restore the standard layout before thinning and signing.
    framework = output / '_internal/Python.framework'
    canonical = framework / 'Versions/3.14/Python'
    for duplicate in [output / '_internal/Python', framework / 'Python', framework / 'Versions/Current/Python']:
        if digest(duplicate) != digest(canonical):
            raise RuntimeError('Unexpected Python framework layout')
    for path, target in [(framework / 'Python', 'Versions/Current/Python'),
                         (framework / 'Resources', 'Versions/Current/Resources'),
                         (framework / 'Versions/Current', '3.14'),
                         (output / '_internal/Python', 'Python.framework/Python')]:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        path.symlink_to(target)
    for path in sorted(output.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as handle:
            magic = handle.read(4)
        if magic not in [bytes.fromhex(value) for value in ['cafebabe', 'cafebabf', 'cffaedfe', 'cefaedfe']]:
            continue
        architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(path)], text=True).split()
        if architectures != ['arm64']:
            subprocess.run(['xcrun', 'lipo', str(path), '-thin', 'arm64', '-output', str(path)], check=True)
        path.chmod(0o755)
        if path.name == 'yt-dlp':
            subprocess.run([sys.executable, str(ROOT / 'Tools/repack_python.py'), str(path)], check=True)
        else:
            # Keep exported symbols used by Python/dlopen; remove local symbols only.
            subprocess.run(['strip', '-x', str(path)], check=True)
        if path != canonical:
            sign(path, private_libraries=path.name == 'yt-dlp')
    sign(framework)
    subprocess.run([str(output / 'yt-dlp'), '--ignore-config', '--version'], check=True)

    with tarfile.open(CACHE / 'quickjs-0.17.0.tar.gz') as archive:
        archive.extractall(CACHE)
    quickjs = CACHE / 'quickjs-0.17.0'
    subprocess.run(['xcrun', 'clang', '-Os', '-arch', 'arm64', '-mmacosx-version-min=13.0',
                    '-D_GNU_SOURCE', '-I', str(quickjs),
                    *[str(quickjs / name) for name in ['dtoa.c', 'libregexp.c', 'libunicode.c', 'quickjs.c']],
                    str(ROOT / 'Tools/QuickJSHost.c'), '-lm', '-lpthread', '-o', str(output / 'qjs')], check=True)
    subprocess.run(['strip', str(output / 'qjs')], check=True)
    sign(output / 'qjs')
    subprocess.run([str(output / 'qjs'), '--version'], check=True)
    source = CACHE / 'ffmpeg-8.0.1'
    if not source.exists():
        with tarfile.open(CACHE / 'ffmpeg-8.0.1.tar.xz') as archive:
            archive.extractall(CACHE)
    log = ROOT / 'build/media-build.log'
    print('Building FFmpeg 8.0.1 (shared, local files only)…', flush=True)
    with log.open('w') as handle:
        if (source / 'ffbuild/config.mak').exists():
            subprocess.run(['make', 'distclean'], cwd=source, stdout=handle, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['./configure', '--arch=arm64', '--target-os=darwin', '--disable-autodetect',
                        '--enable-shared', '--disable-static', '--install-name-dir=@loader_path',
                        '--enable-small', '--disable-doc', '--disable-debug',
                        '--disable-encoders', '--enable-encoder=aac',
                        '--disable-filters', '--enable-filter=aresample',
                        '--disable-muxers', '--enable-muxer=mp4,mov,ipod,matroska,webm,adts,mp3,wav,flac,ogg,opus,mpegts',
                        '--disable-ffplay', '--disable-avdevice', '--disable-network', '--disable-videotoolbox',
                        '--disable-audiotoolbox', '--disable-securetransport', '--disable-protocols', '--enable-protocol=file,pipe',
                        '--extra-cflags=-mmacosx-version-min=13.0', '--extra-ldflags=-mmacosx-version-min=13.0'],
                       cwd=source, stdout=handle, stderr=subprocess.STDOUT, check=True)
        subprocess.run(['make', '-j', str(min(os.cpu_count() or 4, 8))], cwd=source, stdout=handle, stderr=subprocess.STDOUT, check=True)
    for name in ['ffmpeg', 'ffprobe']:
        shutil.copy2(source / name, output / name)
        subprocess.run(['strip', str(output / name)], check=True)
    for name in FFMPEG_LIBRARIES:
        shutil.copy2(source / name.split('.')[0] / name, output / name)
        subprocess.run(['strip', '-x', str(output / name)], check=True)
    for name in [*FFMPEG_LIBRARIES, 'ffmpeg', 'ffprobe']:
        # Ad-hoc executables need this exception to load their private signed dylibs.
        entitlements = ['--entitlements', str(ROOT / 'Resources/Downloader.entitlements')] if name in ['ffmpeg', 'ffprobe'] else []
        subprocess.run(['codesign', '--force', '--options', 'runtime', *entitlements,
                        '--timestamp=none', '--sign', '-', str(output / name)], check=True)
    for name in ['ffmpeg', 'ffprobe']:
        subprocess.run([str(output / name), '-version'], stdout=subprocess.DEVNULL, check=True)
    for name in BINARIES:
        (output / name).chmod(0o755)
        subprocess.run(['xcrun', 'lipo', str(output / name), '-verify_arch', 'arm64'], check=True)
    notices = output / 'licenses'
    notices.mkdir(exist_ok=True)
    shutil.copy2(quickjs / 'LICENSE', notices / 'quickjs-MIT.txt')
    for filename in ['COPYING.LGPLv2.1', 'COPYING.LGPLv3']:
        shutil.copy2(source / filename, notices / filename)
    for name, url in [
        ('yt-dlp-Unlicense.txt', 'https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/LICENSE'),
        ('yt-dlp-third-party.txt', 'https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/THIRD_PARTY_LICENSES.txt'),
    ]:
        with urllib.request.urlopen(url, timeout=60) as response:
            (notices / name).write_bytes(response.read())
    shutil.copy2(ROOT / 'Resources/MediaComponents.md', output / 'MediaComponents.md')


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    manifest = OUTPUT / 'versions.json'
    inputs = {name: digest(ROOT / name) for name in ['Tools/prepare-media.py', 'Tools/repack_python.py', 'Tools/QuickJSHost.c',
               'Resources/Downloader.entitlements', 'Resources/MediaComponents.md']}
    if manifest.exists():
        saved = json.loads(manifest.read_text())
        if (saved.get('versions') == VERSIONS and saved.get('inputs') == inputs and saved.get('sha256') == inventory(OUTPUT)
                and all((OUTPUT / name).is_file() for name in BINARIES)):
            print('Media tools verified.', flush=True)
            return
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(fetch, ASSETS))
    with tempfile.TemporaryDirectory(prefix='media-', dir=ROOT / 'build') as temporary:
        staged = Path(temporary) / 'media-tools'
        staged.mkdir()
        prepare(staged)
        (staged / 'versions.json').write_text(json.dumps({'versions': VERSIONS, 'inputs': inputs, 'sha256': inventory(staged)}, indent=2) + '\n')
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        staged.rename(OUTPUT)
    print('Media tools ready:', OUTPUT, flush=True)


if __name__ == '__main__':
    main()
