# Leafpeak

原生 macOS 下载器。粘贴链接，保存论文、视频、图片或音频。

## 2.3.1

- **论文**：arXiv 编号／链接、Hugging Face 论文页、GitHub PDF、OpenReview、ACL Anthology、CVF 和公开 HTTPS PDF 直链。
- **视频**：YouTube、Bilibili、X、今日头条的单个公开视频链接。自动选择画质；更多菜单中可选「视频仅下载音频」保存 M4A。今日头条使用 `/video/数字/` 详情页，分享短链请先在浏览器打开后复制详情页地址。
- **文件**：HTTPS 图片、音频和视频直链。支持 PNG、JPEG、WebP、GIF、HEIC、TIFF、MP3、M4A、AAC、WAV、FLAC、OGG、Opus、MP4、MOV、WebM、MKV。
- **界面**：「下载」「文档库」「媒体库」三个入口。输入框沿用原有圆角与留白，任务采用轻量列表，日志放入更多菜单。

视频使用内置 yt-dlp、FFmpeg 和 QuickJS-NG，无需另装 Python、Homebrew 或其他运行环境。支持范围以公开、可直接访问的单条内容为主；不支持播放列表、账号主页、X 纯图片帖子，也不导入浏览器登录信息。站点限制、地区限制和已失效内容可能导致失败。

## 安装与使用

支持 Apple Silicon（M 系列芯片），最低 macOS 13。从 [Releases](https://github.com/cleardusk/arxiv-download-ui/releases) 下载 DMG，将 Leafpeak 拖入 Applications；也可使用应用 ZIP。私有仓库需要有访问权限的 GitHub 账号。

当前未做 Apple 公证，首次打开可能需要在系统「隐私与安全性」中允许打开。

1. 粘贴或拖入链接；支持多行、Markdown 和含链接的段落。
2. 选择一个保存位置，默认 `~/Downloads/Leafpeak`；自动归入 `Papers`、`Videos`、`Audio`、`Images`。点击目录可更改位置或在访达中打开。
3. 点击「下载」或按 `⌘ Return`。成功后可打开文件、快速预览或在 Finder 中查看。

子文件夹在首次下载对应类型时创建。升级后新下载使用统一根目录；已有文件和库内路径保留原位置，重试使用当前根目录。

每批最多 200 条，自动去重，最多同时处理三个来源，同一来源串行。失败或取消后保留输入，可逐项重试；新批次开始后，历史结果仍可从下载列表找到。文件重名时按内容复用或添加序号，不覆盖已有文件。

arXiv 默认命名为 `[年份.月份][论文标题].pdf`，精确版本且内容未变的本地 PDF 可直接复用。其他 PDF 用服务器更新标记检查；图片／音视频在下载后校验格式和内容。PDF 上限 256 MiB，媒体文件上限 16 GiB。媒体中断片段保存在本机应用数据目录供重试使用。

## 文档库与媒体库

论文下载成功后自动入库；图片、视频和音频自动进入独立媒体库。支持导入本地 PDF、收藏、已读状态、标签、搜索、排序、重新关联缺失文件及手动检查 arXiv 新版本。移出文档库可恢复，不删除原始 PDF。

媒体库支持搜索、快速预览、打开来源及文件位置。升级时自动收纳现有下载记录中的媒体；清理下载历史不影响媒体库，多文件内容保留为同一项。

升级保留主题及命名偏好、输入草稿、任务和资料库，存储位置保持 `~/Library/Application Support/local.paperrepo.arxiv-downloader/`。文档库与媒体库各自最多 20,000 条；任务历史保留最近 500 条，日志保留最近 1,500 条。损坏／未来版本的资料库会保持原样并进入只读状态。

设置入口为 `⌘ ,`，可调整目录、论文命名、主题、深浅外观及快捷键。首次使用采用石墨主题；已有主题偏好保持不变。

## 命令行

应用内置 CLI，无需启动界面：

```sh
"/Applications/Leafpeak.app/Contents/MacOS/leafpeak" --help
"/Applications/Leafpeak.app/Contents/MacOS/leafpeak" 1706.03762 -o ~/Downloads/Papers
```

另外提供带完整媒体组件的独立 CLI ZIP。`arxiv-download` 保留为应用内兼容别名。[CLI 用法](CLI-README.md)。

## 开发

需要 Apple Command Line Tools 或 Xcode，以及 Python 3 用于准备构建依赖；应用运行不需要这些开发工具。首次构建下载并校验固定版本的媒体组件，从源码构建 FFmpeg，后续复用本机缓存。

```sh
./build.command       # 构建 UI 与 CLI
./test.command        # 离线回归
./package.command     # DMG、应用 ZIP、CLI ZIP 和 SHA-256
```

[构建与发布](RELEASING.md) · [架构与界面](DESIGN.md) · [安全与实测](SECURITY-AUDIT.md) · [媒体组件](Resources/MediaComponents.md)
