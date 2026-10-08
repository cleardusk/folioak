# arxiv-download

Apple Silicon / macOS 13+ 命令行论文下载工具，无需启动 UI。

DMG / 应用 ZIP 已内置 CLI。将应用放入 Applications 后，终端可直接运行：

```sh
"/Applications/arXiv下载器.app/Contents/MacOS/arxiv-download" --help
```

如需短命令，在当前终端设置别名；长期使用可将这一行加入 `~/.zshrc`：

```sh
alias arxiv-download='"/Applications/arXiv下载器.app/Contents/MacOS/arxiv-download"'
arxiv-download https://arxiv.org/html/2605.18678
```

仅使用 CLI 也可下载独立 CLI ZIP，解压后在其目录运行：

```sh
./arxiv-download https://arxiv.org/html/2605.18678 -o ~/Downloads/Papers
./arxiv-download 1706.03762v1 2609.22978v1 --naming id-title --json
```

默认使用 UI 中的保存目录与命名方式。`-o` 和 `--naming` 仅影响本次执行，不修改设置；显式 `-o` 的目录不存在时会创建。命名可选 `date-title`、`id-title`、`title`。自动化脚本建议显式指定目录和命名方式。

支持摘要、PDF、HTML 链接或编号，最多 200 条/批，自动去重。终端中进度原位更新，每篇只保留简短结果，状态使用颜色；设置 `NO_COLOR=1` 可关闭颜色。重定向 stdout 时输出成功文件的绝对路径；`--json` 始终输出无颜色的 schema 1 批次对象。进度与错误写入 stderr。Ctrl+C 取消并清理临时文件，完成的 PDF 保留。

退出码：0 全部成功；1 有失败或待重试项；2 参数或目录错误；130 SIGINT 取消；143 SIGTERM 取消。JSON 的结果状态为 saved、existing、failed、paused、cancelled；暂停项可能包含 retryAfter（ISO 8601）。

同一用户的新版 UI 与 CLI 共享请求间隔、冷却及下载锁；等待其他任务时可以取消。macOS 仍可能要求单独授权终端访问文件夹。内置 CLI 随应用一起升级；独立 CLI 请与 UI 同步更新。

当前为 ad-hoc 签名和 Hardened Runtime，未 Apple 公证。macOS 可能拦截首次运行；请确认下载来源，再按系统「隐私与安全性」提示处理。
