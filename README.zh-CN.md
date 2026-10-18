<p align="center">
  <img src="Resources/FolioakMark.png" width="96" height="96" alt="Folioak logo">
</p>
<h1 align="center">Folioak</h1>
<p align="center"><a href="README.md">English</a> · <strong>简体中文</strong></p>

**原生 macOS 下载器，保存论文、通用文件与媒体。**

- **文档**：arXiv、Hugging Face 论文页、OpenReview、ACL、CVF、GitHub PDF 和公开 PDF 直链。
- **通用文件**：支持 PPT/PPTX、DOC/DOCX、XLS/XLSX、EPUB、OpenDocument、文本/数据文件及 ZIP/7Z/RAR/TAR/GZ/BZ2/XZ 压缩包的公开 HTTPS 直链；无扩展名地址可通过响应头或支持的容器签名识别。
- **媒体**：YouTube、Bilibili、X、今日头条、小红书、抖音、TikTok、Instagram、Vimeo 的单个视频，以及图片／音视频直链。
- **归档**：默认按类型存入 `Papers`、`Documents`、`Archives`、`Videos`、`Audio`、`Images`；可为论文和 PDF 单独选择目录，在文档库和媒体库中查找。

内置完整下载组件，无需安装 Python 或 Homebrew。站点下载取决于当前网络能否公开访问；部分站点对公开视频也要求登录或验证，默认匿名下载，可在设置中主动启用浏览器认证以复用已有登录。不支持播放列表、账号主页和纯图文帖子。小红书请粘贴完整视频分享链接并保留访问参数，也识别 `xhslink.com` 短链。今日头条请使用 `/video/数字/` 详情页链接。

通用文件独立保存在文档库，清空下载历史后仍保留。可使用默认应用打开或系统 Quick Look 预览，具体预览能力取决于系统及已安装的应用。压缩包只保存、不解压；下载验证检查文件签名及容器目录，不逐一解析文档内部对象或验证所有归档内容校验和。

## 安装

[下载最新版](https://github.com/cleardusk/folioak/releases/latest) · Apple Silicon · macOS 13+

打开 DMG，将 Folioak 拖入 Applications。当前未做 Apple 公证，首次打开可能需要在系统「隐私与安全性」中允许打开。

运行期间每天自动检查一次正式版，也可在 **Folioak → 检查更新…** 手动检查；自动检查可在「设置 → 通用」关闭。新版提示提供下载页入口，需手动安装，也可稍后处理或跳过该版本。

## 使用

粘贴或拖入链接，点击下载按钮或按 `⌘ Return`；再次点击可停止。支持多条链接、失败重试和下载后快速预览；双击条目打开文件。点击菜单栏图标也可粘贴下载，下载期间可继续添加。

在「设置 → 通用 → 文件命名」可分别配置 arXiv、文档/PDF、视频、音频、图片与压缩文件。支持 `{title}`、`{date}`、`{source}`、`{id}` 和实时预览；默认保留现有命名方式。日期取任务提交日，规则随任务保存，已有文件不批量改名；重试优先复用已分配名称，同名异内容不会覆盖。音频提取使用音频规则，多附件自动编号；两个资料库均可按实际文件名搜索。

文档库与媒体库均可切换列表／网格，分别记忆选择。网格支持方向键、Shift 连选、Command 多选、空格预览、双击打开和原有管理菜单；缩略图按可见范围加载，不能生成预览时显示文件类型图标。

在「设置 → 通用 → 语言」选择跟随系统、简体中文或 English，切换立即生效。

视频需要登录时，在「设置 → 浏览器认证」选择已登录的浏览器并启用；配置名称可留空。设置页会显示 Cookie 读取结果，每次读取也记入对应任务的日志；读取成功不代表站点已接受登录。macOS 可能要求钥匙串或文件访问权限，认证在支持的站点下载开始时按需读取。认证读取失败或站点拒绝会话时，会自动匿名重试一次；限流、取消和存储错误不触发回退。回退不改变认证设置，也不保证能下载需要验证的内容。任务的更多操作可「在认证浏览器中打开」原链接，或「查看任务日志」，按任务筛选后导出失败原因、回退过程和最终结果。关闭认证后恢复匿名下载，也可清除选择。可用画质取决于视频、平台和账号，登录不保证 4K。Folioak 不导出 cookies 文件，不将 Cookie 内容写入偏好、历史或日志；yt-dlp 可能将浏览器数据库复制到独立私有临时目录，成功、失败或取消后，确认进程组退出再清理；崩溃或无法确认进程退出时仍可能留下临时数据。

全新安装默认保存到 `~/Downloads/Folioak`；分类子文件夹按需创建。在「设置 → 通用 → PDF 目录」可启用单独目录（默认关闭），新论文和 PDF 直接存入所选目录，只保存一份；已有文件不搬动。点击目录即可更改保存位置。升级保留已有设置、文件和资料库；从旧品牌升级时，退出旧应用，安装 Folioak 后将旧应用移出 Applications。

在「设置 → 通用」可主动开启「记录操作轨迹」（默认关闭）。记录仅保存在本机，不上传；用于分析页面切换、下载、文件操作与资料库管理的过程和结果，不包含输入内容、文件名、标签原文、完整链接或 Cookie。最多保留 20 MB / 64 个分段，写入和导出时清理超过 7 天的分段；关闭后已有记录仍可导出或清除。导出目录包含 events.jsonl、timeline.txt 和 metadata.json，可选择本次运行、今天或最近 7 天。用户导出的文件独立保留，不计入本地记录限额。强制退出可能丢失尚未写入的事件，缓冲拥塞或损坏记录会在导出中标明。

[命令行用法](CLI-README.md)

## 开发

运行 `./build.command` 构建，`./test.command` 测试；需要 Xcode 或 Command Line Tools 和 Python 3.9+。

[开发指南（English）](CONTRIBUTING.md) · [构建与发布](RELEASING.md) · [设计](DESIGN.md) · [安全与实测](SECURITY-AUDIT.md) · [媒体组件](Resources/MediaComponents.md)

## 致谢

感谢以下开源项目及其贡献者，Folioak 的相关功能建立在他们的工作之上：

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)：视频网站解析与下载。
- [FFmpeg](https://ffmpeg.org/) 和 ffprobe：媒体信息读取、合并、重新封装与音频提取。
- [QuickJS-NG](https://github.com/quickjs-ng/quickjs)：为 yt-dlp 的 EJS 求解器提供 JavaScript 引擎。
- [CPython](https://github.com/python/cpython)：随 yt-dlp 内置的 Python 运行时。

固定版本、构建方式与许可说明见[媒体组件](Resources/MediaComponents.md)。第三方组件及其内置依赖的许可证与声明随应用附带，位于 `Folioak.app/Contents/Resources/media-tools/licenses/`。

## 许可证

项目源码采用 [MIT 许可证](LICENSE)；内置第三方组件遵循各自许可证。
