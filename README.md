<p align="center">
  <img src="Resources/LeafpeakMark.png" width="96" height="96" alt="Leafpeak logo">
</p>
<h1 align="center">Leafpeak</h1>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

A minimal native macOS downloader for papers, videos, images, and audio.

- **Documents** — arXiv, Hugging Face papers, OpenReview, ACL, CVF, GitHub PDFs, and public PDF links.
- **Media** — individual public videos from YouTube, Bilibili, X, and Toutiao, plus direct image, audio, and video links.
- **Organization** — one download folder, with `Papers`, `Videos`, `Audio`, and `Images` subfolders and built-in document and media libraries.

All download components are bundled. No Python or Homebrew required. Playlists, profiles, image-only X posts, and content requiring login are not supported. For Toutiao, use the full `/video/ID/` page URL.

## Install

[Download the latest release](https://github.com/cleardusk/leafpick/releases/latest) · Apple Silicon · macOS 13+

Open the DMG and drag Leafpeak into Applications. The app is not yet notarized by Apple; you may need to allow it in System Settings → Privacy & Security on first launch.

## Use

Paste or drop links, then click the download button or press `⌘ Return`. Click again to stop. Batch downloads, retries, and Quick Look previews are supported.

The app creates `~/Downloads/Leafpeak` on first launch; type subfolders are created as needed. Click the folder to change the save location. Upgrades preserve your settings, files, and libraries.

[CLI guide (中文)](CLI-README.md)

## Develop

Build with `./build.command`; test with `./test.command`. Requires Xcode or Command Line Tools and Python 3.9+.

[Development guide](CONTRIBUTING.md) · [Build & release (中文)](RELEASING.md) · [Design (中文)](DESIGN.md) · [Security notes (中文)](SECURITY-AUDIT.md) · [Media components (中文)](Resources/MediaComponents.md)

Project source: [MIT](LICENSE). Bundled third-party components retain their own licenses.
