# leafpick

拾取的命令行下载器，支持 Apple Silicon / macOS 13+，无需启动界面。

## 使用

应用内置 CLI：

```sh
"/Applications/Leafpick.app/Contents/MacOS/leafpick" --help
alias leafpick='"/Applications/Leafpick.app/Contents/MacOS/leafpick"'
leafpick 1706.03762 -o ~/Downloads/Papers
leafpick 'https://www.youtube.com/watch?v=jNQXAC9IVRw' -o ~/Downloads
leafpick --audio 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
```

独立 CLI ZIP 解压后运行 `./leafpick`，旁边的 `media-tools` 文件夹必须保留。应用内的旧命令 `arxiv-download` 是兼容别名。

支持论文链接／arXiv 编号，YouTube、Bilibili、X 单个公开视频，以及 HTTPS 图片、音频、视频直链。论文来源包括 Hugging Face、GitHub PDF、OpenReview、ACL Anthology、CVF 和普通 PDF 直链。不支持播放列表、账号主页、X 纯图片帖子或需登录的内容。

`--audio` 对视频站点链接提取 M4A；直链按原格式保存。视频默认自动选择画质，合并可用音视频流。媒体文件经校验后保存；最多 16 GiB，PDF 最多 256 MiB。取消会停止下载器及其转换子进程，媒体下载片段保留供重试，已完成文件保留。

## 输入与输出

```sh
leafpick -i links.md -o ~/Downloads
cat links.txt | leafpick --json
leafpick 1706.03762 -i extra.txt -i - < more.txt
leafpick -i links.md --verbose
```

`-i` 可指定多个 UTF-8 文件，`-i -` 或独立 `-` 表示标准输入。无链接和文件参数且 stdin 非终端时自动读取。支持从 Markdown／段落提取链接，合计最多 64 KiB、200 条（去重前）。读取管道时可 Ctrl+C 取消。

默认沿用 UI 的保存目录与论文命名。`-o` 和 `--naming` 仅影响本次执行；显式 `-o` 的目录不存在时会创建。arXiv 命名可选 `date-title`、`id-title`、`title`，其他文件按标题或原名保存。同名按内容复用或添加序号，不覆盖已有文件。

最多同时处理三个输入来源，同一来源串行。arXiv 继续共享 UI 的请求间隔、冷却和下载锁。媒体工具随包提供，不读取用户 yt-dlp 配置或浏览器 cookies。

终端显示简短进度和结果，`NO_COLOR=1` 关闭颜色。重定向 stdout 时逐行输出所有成功文件的绝对路径；`--json` 输出 schema 1 批次对象，结果按输入顺序排列。进度和错误写入 stderr，`--verbose` 额外显示阶段与耗时。

JSON 状态：saved、existing、failed、paused、cancelled；暂停项可能包含 ISO 8601 的 retryAfter。PDF 结果包含 pages；一条链接产生多个文件时，path 为第一个文件，其余位于可选 additionalPaths 数组。

退出码：0 全部成功；1 有失败或待重试项；2 参数或目录错误；130 SIGINT 取消；143 SIGTERM 取消。

当前为 ad-hoc 签名，未 Apple 公证。首次运行可能需要按系统「隐私与安全性」提示允许。独立 CLI 请与 UI 同步更新。
