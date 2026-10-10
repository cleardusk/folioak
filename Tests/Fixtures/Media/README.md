# Synthetic media fixtures

These files are generated test signals, not downloaded media. They are committed so
the production bundle does not need unused video, lossless-audio or MP3 encoders
just to run tests. No fixture generation tools are required by CI or end users.

- `tone.*`: 0.25 seconds of a 440 Hz sine wave at 48 kHz, signed 16-bit PCM,
  amplitude 8000. Encoded as AAC (ADTS and M4A), MP2, MP3, FLAC, Vorbis and Opus.
- `video.mp4`: one constant gray 16 × 16 YUV420P frame, MPEG-4 Part 2, 4 fps.
- `h264.mp4`, `hevc.mp4`, `vp9.webm`: the same frame encoded with libx264,
  libx265 and libvpx-vp9.
- `av1.mp4`: a constant gray 64 × 64 YUV420P frame, libsvtav1, 4 fps.

To regenerate, write a raw frame with every byte set to 128 (384 bytes for 16 × 16;
6144 bytes for 64 × 64) and pass it to a development FFmpeg build with
`-f rawvideo -pixel_format yuv420p -video_size WIDTHxHEIGHT -framerate 4 -i frame.yuv`.
Use the encoder listed above. The audio signal is
`int(8000 * sin(2 * pi * 440 * i / 48000))` for samples 0 through 11999.
The Vorbis fixture uses two identical channels. All other audio fixtures are mono.
