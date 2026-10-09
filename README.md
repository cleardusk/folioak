# arXiv下载器

原生 macOS 论文下载工具：粘贴 arXiv 链接／编号、Hugging Face 论文页或通用 HTTPS PDF 直链，自动命名并保存。

## 安装

支持 Apple Silicon（M 系列芯片），最低 macOS 13。

从 [Releases](https://github.com/cleardusk/arxiv-download-ui/releases) 下载 DMG，将应用拖入 Applications；也可下载 ZIP 解压安装。私有仓库需登录有访问权限的 GitHub 账号。

当前未做 Apple 公证，首次打开可能需要在系统「隐私与安全性」中允许打开。

## 使用

1. 粘贴一个或多个链接／编号，每行一个。
2. 选择保存目录，点击「开始下载」。

arXiv 默认命名为 `[arXiv年份.月份][论文标题].pdf`；通用 PDF 使用文档标题或原文件名。支持混合输入、链接去重、失败重试和取消，不覆盖已有文件；每批最多 200 条。

HF 论文页（如 `https://huggingface.co/papers/2608.15763`）自动转为 arXiv 下载，与相同编号或 arXiv 链接去重；支持版本号、分享参数及 `hf.co` 短域名，无需访问 HF 网页。

每篇保存成功后移除对应输入，下载结果保留在列表；失败或取消的链接保留。

arXiv 精确版本且内容未变的本地 PDF 直接复用。通用 PDF 用服务器更新标记检查，未更新则复用；无更新标记或发生重定向时重新下载校验。

限流时自动等待，持续限流会暂停该站点的下载，其余站点继续；输入和已完成结果保留，等待可取消，重启不会清除冷却期。

设置可调整目录、文件命名、深浅外观及六套主题。`⌘ Return` 开始下载，`⌘ ,` 打开设置。

## 2.0 新增

- FlClash 风格的三页工作台：下载、资料库、日志；支持侧栏收起、六套主题与深浅外观。
- 下载进度与速率、状态筛选、单项 / 批量重试、复制未完成链接。
- 从 UTF-8 文本导入链接；输入草稿和当前任务在重启后恢复。中断任务等待手动重试。
- 资料库最多保留最近 500 条下载记录，可搜索、打开 PDF、定位文件、导出 JSON 索引；丢失文件可重新下载。
- 日志按级别和关键词筛选、跟随最新、复制 / 导出，最多保留最近 1,500 条，自动隐藏 URL 查询参数、片段及凭据。
- 状态原子写入本机 `~/Library/Application Support/local.paperrepo.arxiv-downloader/workspace.json`；损坏记录先保留备份再写入新状态。旧版文件不自动扫描入库。
- 状态文件上限 8 MiB；超长历史或日志触及上限时优先移除旧记录，保留当前任务和草稿。

## 命令行

DMG / 应用 ZIP 已内置 CLI，安装一次即可同时使用 UI 和命令行，无需启动 UI：

```sh
"/Applications/arXiv下载器.app/Contents/MacOS/arxiv-download" --help
```

UI 与 CLI 共用默认目录、命名及限流；命令参数只影响本次执行。仅使用 CLI 也可下载独立 CLI ZIP。[CLI 用法](CLI-README.md)。

## 开发

需要 Apple Command Line Tools 或 Xcode，应用运行无需额外依赖。

```sh
./build.command     # 构建 UI 与 CLI
./test.command      # 离线回归
./package.command   # 生成 UI / CLI 安装包和校验文件
```

[构建与发布](RELEASING.md) · [架构与界面](DESIGN.md) · [安全与实测](SECURITY-AUDIT.md)
