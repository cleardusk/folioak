#!/usr/bin/env python3
"""Offline integration tests against the actual bundled yt-dlp and FFmpeg."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'Tests/Fixtures/Media'
SOURCE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'build/media-tools'


def run(args):
    result = subprocess.run([str(arg) for arg in args], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=90, env={**os.environ, 'PATH': '/usr/bin:/bin'})
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}):\n{result.stderr}\n{result.stdout}')
    return result.stdout


with tempfile.TemporaryDirectory(prefix='media-tools-', dir=ROOT / 'build') as temporary:
    folder = Path(temporary)
    # Exercise relocation, spaces in paths and private library loading without Homebrew.
    tools = folder / 'relocated tools'
    shutil.copytree(SOURCE, tools)
    ffmpeg, ffprobe = tools / 'ffmpeg', tools / 'ffprobe'
    for binary in [ffmpeg, ffprobe, *tools.glob('*.dylib')]:
        run(['codesign', '--verify', '--strict', binary])
        for line in run(['otool', '-L', binary]).splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            assert dependency.startswith(('/usr/lib/', '/System/Library/', '@loader_path/')), dependency
            if dependency.startswith('@loader_path/'):
                assert (tools / dependency.split('/', 1)[1]).is_file(), dependency

    def probe(path):
        return json.loads(run([ffprobe, '-v', 'error', '-show_streams', '-of', 'json', path]))['streams']

    def packets(path, kind):
        data = json.loads(run([ffprobe, '-v', 'error', '-select_streams', kind, '-show_packets',
                              '-show_data_hash', 'sha256', '-show_entries', 'packet=data_hash',
                              '-of', 'json', path]))['packets']
        return [packet['data_hash'] for packet in data]

    def download(info, name, *options):
        manifest = folder / f'{name}.json'
        manifest.write_text(json.dumps({'id': name, 'title': name, 'extractor': 'fixture', **info}))
        run([tools / 'yt-dlp', '--ignore-config', '--no-plugin-dirs', '--no-remote-components',
             '--no-update', '--no-cache-dir', '--no-js-runtimes', '--enable-file-urls',
             '--ffmpeg-location', tools, '--load-info-json', manifest,
             '--output', folder / f'{name}.%(ext)s', *options])
        outputs = [p for p in folder.glob(f'{name}.*') if p.suffix != '.json']
        assert len(outputs) == 1, outputs
        return outputs[0]

    # These are decoder inputs, not features that require output encoders.
    for extension, codec in [('wav', 'pcm_s16le'), ('mp3', 'mp3'), ('mp2', 'mp2'),
                             ('flac', 'flac'), ('ogg', 'vorbis'), ('opus', 'opus'),
                             ('aac', 'aac'), ('m4a', 'aac')]:
        source = FIXTURES / f'tone.{extension}'
        assert probe(source)[0]['codec_name'] == codec
        output = download({'url': source.as_uri(), 'ext': extension, 'vcodec': 'none', 'acodec': codec},
                          f'audio-{extension}', '--extract-audio', '--audio-format', 'm4a')
        assert output.suffix == '.m4a'
        streams = probe(output)
        assert len(streams) == 1 and streams[0]['codec_name'] == 'aac', streams
        # Decode every audio packet, checking that the result is actually usable.
        run([ffmpeg, '-v', 'error', '-xerror', '-i', output, '-c:a', 'aac', folder / f'checked-{extension}.m4a'])
        if extension in ('aac', 'm4a'):
            # Both AAC fixtures contain the same payload; ADTS headers are removed in M4A.
            assert packets(FIXTURES / 'tone.m4a', 'a') == packets(output, 'a'), 'AAC must remain lossless'

    for filename, codec, audio_name, audio_codec in [
        ('h264.mp4', 'h264', 'tone.m4a', 'aac'),
        ('hevc.mp4', 'hevc', 'tone.m4a', 'aac'),
        ('av1.mp4', 'av1', 'tone.m4a', 'aac'),
        ('vp9.webm', 'vp9', 'tone.opus', 'opus'),
        ('video.mp4', 'mpeg4', 'tone.m4a', 'aac'),
    ]:
        video, audio = FIXTURES / filename, FIXTURES / audio_name
        formats = [
            {'format_id': 'v', 'url': video.as_uri(), 'ext': video.suffix[1:],
             'vcodec': codec, 'acodec': 'none', 'width': 16, 'height': 16},
            {'format_id': 'a', 'url': audio.as_uri(), 'ext': audio.suffix[1:],
             'vcodec': 'none', 'acodec': audio_codec},
        ]
        output = download({'formats': formats}, f'merge-{codec}', '--format', 'bv*+ba/b',
                          '--merge-output-format', 'mp4/mkv')
        assert output.suffix in ('.mp4', '.mkv')
        assert {s['codec_name'] for s in probe(output)} == {codec, audio_codec}
        assert packets(video, 'v') == packets(output, 'v'), 'Video packets changed during merge'
        assert packets(audio, 'a') == packets(output, 'a'), 'Audio packets changed during merge'

    # Native HLS downloads need MPEG-TS -> MP4 repair and the AAC bitstream filter.
    segment = folder / 'segment.ts'
    run([ffmpeg, '-v', 'error', '-i', FIXTURES / 'h264.mp4', '-i', FIXTURES / 'tone.m4a',
         '-map', '0:v', '-map', '1:a', '-c', 'copy', '-f', 'mpegts', segment])
    playlist = folder / 'playlist.m3u8'
    playlist.write_text('#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n'
                        '#EXTINF:0.25,\nsegment.ts\n#EXT-X-ENDLIST\n')
    class QuietHandler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(folder)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        output = download({'url': f'http://127.0.0.1:{server.server_port}/playlist.m3u8',
                           'ext': 'mp4', 'protocol': 'm3u8_native'}, 'hls')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert {s['codec_name'] for s in probe(output)} == {'h264', 'aac'}
    format_name = json.loads(run([ffprobe, '-v', 'error', '-show_entries', 'format=format_name',
                                 '-of', 'json', output]))['format']['format_name']
    assert 'mp4' in format_name, format_name

    invalid = folder / 'invalid.mp4'
    invalid.write_text('<html>not a video</html>')
    assert subprocess.run([str(ffprobe), '-v', 'error', str(invalid)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0

print('PASS media tools: relocated signed libraries, eight audio formats, lossless AAC, '
      'five video merge formats, HLS repair and invalid-file rejection')
