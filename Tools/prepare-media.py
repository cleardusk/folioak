#!/usr/bin/env python3
"""Prepare pinned, self-contained macOS arm64 media tools for the app and CLI."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / 'build/media-sources'
OUTPUT = ROOT / 'build/media-tools'
VERSIONS = {'yt-dlp': '2026.08.19', 'deno': '2.9.7', 'ffmpeg': '8.0.1', 'recipe': 2}
FFMPEG_LIBRARIES = ['libavcodec.62.dylib', 'libavfilter.11.dylib', 'libavformat.62.dylib',
                    'libavutil.60.dylib', 'libswresample.6.dylib', 'libswscale.9.dylib']
BINARIES = ['yt-dlp', 'deno', 'ffmpeg', 'ffprobe', *FFMPEG_LIBRARIES]
ASSETS = [
    ('yt-dlp', 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos',
     '0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202'),
    ('deno.zip', 'https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip',
     '5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c'),
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


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest = OUTPUT / 'versions.json'
    if manifest.exists():
        saved = json.loads(manifest.read_text())
        if (saved.get('versions') == VERSIONS and set(saved.get('sha256', {})) == set(BINARIES)
                and all((OUTPUT / name).exists() and digest(OUTPUT / name) == sha for name, sha in saved['sha256'].items())):
            print('Media tools verified.', flush=True)
            shutil.copy2(ROOT / 'Resources/MediaComponents.md', OUTPUT / 'MediaComponents.md')
            return
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(fetch, ASSETS))
    shutil.copy2(CACHE / 'yt-dlp', OUTPUT / 'yt-dlp')
    with zipfile.ZipFile(CACHE / 'deno.zip') as archive:
        (OUTPUT / 'deno').write_bytes(archive.read('deno'))
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
        shutil.copy2(source / name, OUTPUT / name)
        subprocess.run(['strip', str(OUTPUT / name)], check=True)
    for name in FFMPEG_LIBRARIES:
        shutil.copy2(source / name.split('.')[0] / name, OUTPUT / name)
        subprocess.run(['strip', '-x', str(OUTPUT / name)], check=True)
    for name in [*FFMPEG_LIBRARIES, 'ffmpeg', 'ffprobe']:
        # Ad-hoc executables need this exception to load their private signed dylibs.
        entitlements = ['--entitlements', str(ROOT / 'Resources/Downloader.entitlements')] if name in ['ffmpeg', 'ffprobe'] else []
        subprocess.run(['codesign', '--force', '--options', 'runtime', *entitlements,
                        '--timestamp=none', '--sign', '-', str(OUTPUT / name)], check=True)
    for name in ['ffmpeg', 'ffprobe']:
        subprocess.run([str(OUTPUT / name), '-version'], stdout=subprocess.DEVNULL, check=True)
    for name in BINARIES:
        (OUTPUT / name).chmod(0o755)
        subprocess.run(['xcrun', 'lipo', str(OUTPUT / name), '-verify_arch', 'arm64'], check=True)
    notices = OUTPUT / 'licenses'
    notices.mkdir(exist_ok=True)
    for filename in ['COPYING.LGPLv2.1', 'COPYING.LGPLv3']:
        shutil.copy2(source / filename, notices / filename)
    for name, url in [
        ('yt-dlp-Unlicense.txt', 'https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/LICENSE'),
        ('yt-dlp-third-party.txt', 'https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/THIRD_PARTY_LICENSES.txt'),
        ('deno-MIT.txt', 'https://raw.githubusercontent.com/denoland/deno/v2.9.7/LICENSE.md'),
    ]:
        with urllib.request.urlopen(url, timeout=60) as response:
            (notices / name).write_bytes(response.read())
    shutil.copy2(ROOT / 'Resources/MediaComponents.md', OUTPUT / 'MediaComponents.md')
    manifest.write_text(json.dumps({'versions': VERSIONS, 'sha256': {name: digest(OUTPUT / name) for name in BINARIES}}, indent=2) + '\n')
    print('Media tools ready:', OUTPUT, flush=True)


if __name__ == '__main__':
    main()
