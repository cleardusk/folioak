<p align="center">
  <img src="Resources/FolioakMark.png" width="96" height="96" alt="Folioak logo">
</p>
<h1 align="center">Folioak</h1>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

**A native macOS downloader for papers, files, and media.**

- **Papers** — arXiv, Hugging Face papers, OpenReview, ACL, CVF, GitHub PDFs, and public PDF links.
- **Files** — public HTTPS links to Office documents, EPUB, OpenDocument, text/data files, and archives. Archives are saved without extraction.
- **Media** — individual videos from YouTube, Bilibili, X, Toutiao, Xiaohongshu, Douyin, TikTok, Instagram, and Vimeo, plus direct image, audio, and video links.

Includes document and media libraries, batch downloads, retries, and previews. All download components are bundled; no Python or Homebrew required.

## Install

[Download the latest release](https://github.com/cleardusk/folioak/releases/latest) · **Apple Silicon · macOS 13+**

Open the DMG and drag Folioak into Applications. The app is not yet notarized by Apple; first launch may require approval in System Settings → Privacy & Security.

Folioak checks for stable updates daily while running. Automatic checks can be disabled in Settings; **Folioak → Check for Updates…** checks manually. Updates open the release page for manual installation. Upgrades preserve your settings, files, and libraries.

## Use

1. Paste or drop links, then click Download or press `⌘ Return`. Click again to stop. The menu bar panel also accepts links, including during a download.
2. Find saved files in the document or media library. Switch between list and grid, double-click to open, or press Space to preview. Clearing download history keeps library entries and files.
3. Set your save location, language, and appearance in Settings. Naming Rules supports `{title}`, `{date}`, `{source}`, and `{id}` with a live preview; existing files are never overwritten.

New installations save to `~/Downloads/Folioak`, organized by file type. Settings → General → PDF folder can send new papers and PDFs directly to a separate folder (off by default); existing files stay in place. The [CLI](CLI-README.md) shares these settings, with explicit `-o` / `--output` taking priority for all files in that run.

Themes include the original six palettes plus **VS Code, One Dark, Dracula, Nord, Solarized, and Gruvbox**, each with light and dark appearances. Settings categories use the library's sliding underline, with horizontal scrolling, arrow-key navigation, and Reduce Motion support.

**Site limits:** media downloads are anonymous by default. For supported sites that need sign-in, enable Settings → Browser Authentication and choose an already signed-in browser. Access and quality still depend on the site, network, and account. Playlists, profiles, and image-only posts are unsupported. Keep access parameters in Xiaohongshu video share links (`xhslink.com` short links also work); use full `/video/ID/` URLs for Toutiao.

**Privacy:** preferences, history, and logs stay on this Mac; there is no uploaded telemetry, cloud sync, or background folder scanning. Optional interaction recording is off by default and excludes input text, filenames, full URLs, and cookies. Browser authentication may request macOS permissions and create temporary browser database copies; Cookie contents are not stored in preferences, history, or logs. See [security and privacy details (中文)](SECURITY-AUDIT.md).

## Develop

Run `./build.command` to build and `./test.command` to test. Requires Xcode or Command Line Tools and Python 3.9+; the first run downloads and builds pinned media dependencies.

[Development guide](CONTRIBUTING.md) · [Build & release (中文)](RELEASING.md) · [Design (中文)](DESIGN.md) · [CLI guide (中文)](CLI-README.md)

## License & acknowledgments

Project source: [MIT](LICENSE). Thanks to [yt-dlp](https://github.com/yt-dlp/yt-dlp), [FFmpeg](https://ffmpeg.org/), [QuickJS-NG](https://github.com/quickjs-ng/quickjs), and [CPython](https://github.com/python/cpython).

Bundled components retain their own licenses. Versions and build details are in [Media components](Resources/MediaComponents.md); license texts ship in `Folioak.app/Contents/Resources/media-tools/licenses/`.
