<p align="center">
  <img src="Resources/FolioakMark.png" width="96" height="96" alt="Folioak logo">
</p>
<h1 align="center">Folioak</h1>
<p align="center"><a href="README.md">English</a> · <strong>简体中文</strong></p>

**原生 macOS 下载器，保存论文、通用文件与媒体。**

- **论文**：arXiv、Hugging Face 论文页、OpenReview、ACL、CVF、GitHub PDF 和公开 PDF 直链。
- **文件**：Office、EPUB、OpenDocument、文本／数据文件与压缩包的公开 HTTPS 直链。压缩包只保存，不解压。
- **媒体**：YouTube、Bilibili、X、今日头条、小红书、抖音、TikTok、Instagram、Vimeo 的单个视频，以及图片／音视频直链。

提供文档库、媒体库、批量下载、重试和预览。下载组件已内置，无需安装 Python 或 Homebrew。

## 安装

[下载最新版](https://github.com/cleardusk/folioak/releases/latest) · **Apple Silicon · macOS 13+**

打开 DMG，将 Folioak 拖入 Applications。当前未做 Apple 公证，首次打开可能需要在系统「隐私与安全性」中允许打开。

运行期间每天检查一次正式版，可在设置中关闭自动检查，也可通过 **Folioak → 检查更新…** 手动检查。更新提示会打开发布页，需手动安装；升级保留已有设置、文件和资料库。

## 使用

1. 粘贴或拖入链接，点击下载或按 `⌘ Return`，再次点击可停止。菜单栏面板也可输入链接，下载中可继续添加。
2. 在文档库或媒体库查找文件，切换列表／网格，双击打开或按空格预览。清空下载历史不会删除资料库条目或文件。
3. 在设置中调整保存位置、语言和外观。「命名规则」支持 `{title}`、`{date}`、`{source}`、`{id}` 和实时预览，已有文件不会被覆盖。

全新安装默认保存到 `~/Downloads/Folioak`，按文件类型归档。「设置 → 通用 → PDF 目录」可让新论文和 PDF 直接存入独立目录（默认关闭），已有文件不搬动。[命令行](CLI-README.md)共用这些设置，显式 `-o` / `--output` 优先指定本次所有文件的保存位置。

主题包含原有六套配色，以及 **VS Code、One Dark、Dracula、Nord、Solarized、Gruvbox**，均适配浅色与深色外观。设置分类沿用资料库的滑动下划线，支持横向滚动、方向键切换和系统「减少动态效果」。

**站点限制：** 媒体默认匿名下载。支持的站点需要登录时，可在「设置 → 浏览器认证」选择已登录的浏览器并启用认证；能否访问及可用画质仍取决于站点、网络和账号。不支持播放列表、账号主页和纯图文帖子。小红书视频分享链接请保留访问参数（也支持 `xhslink.com` 短链）；今日头条请使用完整的 `/video/数字/` 详情页链接。

**隐私：** 偏好、历史和日志仅保存在本机，无上传遥测、云同步或后台目录扫描。「记录操作轨迹」默认关闭，不记录输入内容、文件名、完整链接或 Cookie。浏览器认证可能申请 macOS 权限并创建浏览器数据库临时副本；Cookie 内容不写入偏好、历史或日志。详见[安全与隐私说明](SECURITY-AUDIT.md)。

## 开发

运行 `./build.command` 构建，`./test.command` 测试。需要 Xcode 或 Command Line Tools 和 Python 3.9+；首次运行会下载并构建固定版本的媒体依赖。

[开发指南（English）](CONTRIBUTING.md) · [构建与发布](RELEASING.md) · [设计](DESIGN.md) · [命令行用法](CLI-README.md)

## 许可与致谢

项目源码采用 [MIT 许可证](LICENSE)。感谢 [yt-dlp](https://github.com/yt-dlp/yt-dlp)、[FFmpeg](https://ffmpeg.org/)、[QuickJS-NG](https://github.com/quickjs-ng/quickjs) 和 [CPython](https://github.com/python/cpython)。

内置组件遵循各自许可证；版本与构建说明见[媒体组件](Resources/MediaComponents.md)，许可证随应用附带于 `Folioak.app/Contents/Resources/media-tools/licenses/`。
