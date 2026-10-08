# arXiv下载器

原生 macOS 论文下载工具：粘贴 arXiv 链接或编号，自动命名并保存 PDF。

## 安装

支持 Apple Silicon（M 系列芯片），最低 macOS 13。

从 [Releases](https://github.com/cleardusk/arxiv-download-ui/releases) 下载 DMG，将应用拖入 Applications；也可下载 ZIP 解压安装。私有仓库需登录有访问权限的 GitHub 账号。

当前未做 Apple 公证，首次打开可能需要在系统「隐私与安全性」中允许打开。

## 使用

1. 粘贴一个或多个链接／编号，每行一个。
2. 选择保存目录，点击「开始下载」。

默认命名为 `[arXiv年份.月份][论文标题].pdf`。支持指定版本、链接去重、失败重试和取消，不覆盖已有文件；每批最多 200 条。

每篇保存成功后移除对应输入，下载结果保留在列表；失败或取消的链接保留。

已记录来源、精确版本且内容未变的本地 PDF 直接复用；旧文件首次仍需下载校验。

限流时自动等待，持续限流会暂停批次，输入和已完成结果保留；等待可取消，重启不会清除冷却期。

设置可调整目录、文件命名、深浅外观及六套主题。`⌘ Return` 开始下载，`⌘ ,` 打开设置。

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
