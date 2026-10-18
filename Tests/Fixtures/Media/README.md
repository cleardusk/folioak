# Synthetic media fixtures

Generated test signals, not downloaded media. Committed fixtures let CI and end users run tests without generation tools or extra encoders in the production bundle.

| Files | Signal and encoding |
| --- | --- |
| `tone.*` | 0.25 s, 440 Hz sine wave, 48 kHz signed 16-bit PCM, amplitude 8000; WAV, AAC (ADTS/M4A), MP2, MP3, FLAC, Vorbis, Opus. |
| `video.mp4` | One gray 16 × 16 YUV420P frame, MPEG-4 Part 2, 4 fps. |
| `h264.mp4`, `hevc.mp4`, `vp9.webm` | Same frame, encoded with libx264, libx265, and libvpx-vp9 respectively. |
| `av1.mp4` | One gray 64 × 64 YUV420P frame, libsvtav1, 4 fps. |

To regenerate video, set every raw-frame byte to 128 (384 bytes for 16 × 16; 6144 for 64 × 64). Use a development FFmpeg build with the encoder above and `-f rawvideo -pixel_format yuv420p -video_size WIDTHxHEIGHT -framerate 4 -i frame.yuv`.

For audio, generate `int(8000 * sin(2 * pi * 440 * i / 48000))` for samples 0–11999. Vorbis uses two identical channels; all other audio fixtures are mono.
