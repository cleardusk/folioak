<p align="center">
  <img src="Resources/FolioakMark.png" width="96" height="96" alt="Folioak logo">
</p>
<h1 align="center">Folioak</h1>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

**A native macOS downloader for papers and media.**

- **Documents** — arXiv, Hugging Face papers, OpenReview, ACL, CVF, GitHub PDFs, and public PDF links.
- **Media** — individual videos from YouTube, Bilibili, X, Toutiao, Xiaohongshu, Douyin, TikTok, Instagram, and Vimeo, plus direct image, audio, and video links.
- **Organization** — one download folder, with `Papers`, `Videos`, `Audio`, and `Images` subfolders and built-in document and media libraries.

All download components are bundled. No Python or Homebrew required. Site downloads depend on public access from your network; some sites require login or verification even for public videos. Media downloads are anonymous by default. You can opt in to browser authentication in Settings to reuse an existing browser session. Playlists, profiles and image-only posts are not supported. For Xiaohongshu, paste the full video share link, keeping its access parameters; `xhslink.com` short links are also recognized. For Toutiao, use the full `/video/ID/` page URL.

## Install

[Download the latest release](https://github.com/cleardusk/folioak/releases/latest) · Apple Silicon · macOS 13+

Open the DMG and drag Folioak into Applications. The app is not yet notarized by Apple; you may need to allow it in System Settings → Privacy & Security on first launch.

## Use

Paste or drop links, then click the download button or press `⌘ Return`. Click again to stop. Batch downloads, retries, and Quick Look previews are supported.

Choose System, 简体中文, or English in Settings → General → Language. Changes take effect immediately.

For videos that need sign-in, open Settings → Browser Authentication, choose the browser where you are already signed in, and enable authentication. Profile selection is optional. Settings and task logs report cookie-read results; a successful read does not confirm site sign-in. macOS may request Keychain or file access. Authentication is read when a supported site download starts. Turn it off to return to anonymous downloads, or clear the selection. Available quality still depends on the video, site and account; signing in does not guarantee 4K. Folioak does not export a cookies file or keep Cookie contents in its preferences, history or logs. yt-dlp may copy browser databases into a private temporary directory, cleaned after success, failure or cancellation once the process group exits. A crash or unconfirmed process exit can leave temporary data behind.

New installations use `~/Downloads/Folioak`; type subfolders are created as needed. Click the folder to change the save location. Upgrades preserve your settings, files, and libraries. When upgrading from an earlier product name, quit and move the old app out of Applications after installing Folioak.

[CLI guide (中文)](CLI-README.md)

## Develop

Build with `./build.command`; test with `./test.command`. Requires Xcode or Command Line Tools and Python 3.9+.

[Development guide](CONTRIBUTING.md) · [Build & release (中文)](RELEASING.md) · [Design (中文)](DESIGN.md) · [Security notes (中文)](SECURITY-AUDIT.md) · [Media components (中文)](Resources/MediaComponents.md)

## Acknowledgments

Folioak builds on the work of these open-source projects and their contributors:

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — video site extraction and downloads.
- [FFmpeg](https://ffmpeg.org/) and ffprobe — media inspection, merging, remuxing, and audio extraction.
- [QuickJS-NG](https://github.com/quickjs-ng/quickjs) — the JavaScript engine used by yt-dlp's EJS solver.
- [CPython](https://github.com/python/cpython) — the Python runtime bundled with yt-dlp.

See [Media components](Resources/MediaComponents.md) for pinned versions, build details, and licensing notes. Third-party license texts and notices, including those for bundled dependencies, are included in `Folioak.app/Contents/Resources/media-tools/licenses/`.

## License

Project source: [MIT](LICENSE). Bundled third-party components retain their own licenses.
