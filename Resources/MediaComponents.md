# Media components

The app bundles these separate command-line tools. It does not download code, read browser cookies, load user yt-dlp configuration/plugins, or update itself at runtime. Component updates ship with an application update after validation. Build inputs and SHA-256 hashes are pinned in `Tools/prepare-media.py`.

- yt-dlp 2026.08.19: https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19 — upstream source is Unlicense; the official macOS PyInstaller distribution includes GPLv3+ components. See the included third-party license file and https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/README.md#licensing. EJS is included in this distribution.
- Deno 2.9.7: https://github.com/denoland/deno/releases/tag/v2.9.7 — MIT, plus its third-party licenses. Used for yt-dlp's restricted JavaScript challenge solver.
- FFmpeg / ffprobe 8.0.1: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz — built from unmodified source, LGPL configuration, static libraries, without GPL/nonfree/external libraries or networking. The exact configure invocation is in `Tools/prepare-media.py`; copyright/license texts are included. Source and build instructions allow rebuilding these independent executables.

Media downloads are limited to individual YouTube, Bilibili and X URLs. Access-controlled content may require authentication; this version does not import browser credentials. Direct HTTPS image/audio/video links use the native transport. Partial yt-dlp transfers are kept in the app's `MediaDownloads` support directory for retry; successful output is validated before publication. The default output uses an available video+audio combination; audio extraction saves M4A. PDFs retain the existing paper workflow.
