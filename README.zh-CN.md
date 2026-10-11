<p align="center">
  <img src="Resources/LeafpeakMark.png" width="96" height="96" alt="Leafpeak logo">
</p>
<h1 align="center">Leafpeak</h1>
<p align="center"><a href="README.md">English</a> · <strong>简体中文</strong></p>

原生 macOS 下载器。粘贴链接，保存论文、视频、图片和音频。

- **文档**：arXiv、Hugging Face 论文页、OpenReview、ACL、CVF、GitHub PDF 和公开 PDF 直链。
- **媒体**：YouTube、Bilibili、X、今日头条的单个公开视频，以及图片／音视频直链。
- **归档**：一个保存位置，自动分入 `Papers`、`Videos`、`Audio`、`Images`，可在文档库和媒体库中查找。

内置完整下载组件，无需安装 Python 或 Homebrew。仅支持公开可访问的内容；不支持播放列表、账号主页、X 纯图片帖子或登录内容。今日头条请使用 `/video/数字/` 详情页链接。

## 安装

[下载最新版](https://github.com/cleardusk/leafpick/releases/latest) · Apple Silicon · macOS 13+

打开 DMG，将 Leafpeak 拖入 Applications。当前未做 Apple 公证，首次打开可能需要在系统「隐私与安全性」中允许打开。

## 使用

粘贴或拖入链接，点击下载按钮或按 `⌘ Return`；再次点击可停止。支持多条链接、失败重试和下载后快速预览。

首次启动自动创建 `~/Downloads/Leafpeak`；分类子文件夹按需创建。点击目录即可更改保存位置。升级保留已有设置、文件和资料库。

[命令行用法](CLI-README.md)

## 开发

运行 `./build.command` 构建，`./test.command` 测试；需要 Xcode 或 Command Line Tools 和 Python 3.9+。

[开发指南（English）](CONTRIBUTING.md) · [构建与发布](RELEASING.md) · [设计](DESIGN.md) · [安全与实测](SECURITY-AUDIT.md) · [媒体组件](Resources/MediaComponents.md)

项目源码采用 [MIT 许可证](LICENSE)；内置第三方组件遵循各自许可证。
