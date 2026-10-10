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
./arxiv-download https://huggingface.co/papers/2608.15763
./arxiv-download https://github.com/openai/math/blob/main/overview.pdf
./arxiv-download https://aclanthology.org/2023.emnlp-main.1/
./arxiv-download 1706.03762v1 2609.22978v1 --naming id-title --json
```

文件与管道输入：

```sh
arxiv-download -i papers.md -o ~/Downloads/Papers
cat papers.txt | arxiv-download --json
arxiv-download 1706.03762 -i extra.txt -i - < more.txt
arxiv-download -i papers.md --verbose
```

`-i` 可指定多个 UTF-8 文件，`-i -` 或独立的 `-` 表示标准输入；无链接和文件参数且 stdin 非终端时自动读取。文件／管道中的 Markdown、段落自动提取链接和编号，纯链接输入保持原样；合计最多 64 KiB，最多 200 条（去重前）。读取结束后才开始下载，等待管道时仍可 Ctrl+C 取消。`--verbose` 在 stderr 显示阶段、耗时和重试次数，不改变 stdout 路径或 JSON。

默认使用 UI 中的保存目录与命名方式。`-o` 和 `--naming` 仅影响本次执行，不修改设置；显式 `-o` 的目录不存在时会创建。arXiv 命名可选 `date-title`、`id-title`、`title`；通用 PDF 使用文档标题或原文件名。自动化脚本建议显式指定目录和命名方式。

支持 arXiv 摘要、PDF、HTML 链接或编号、Hugging Face 论文页、GitHub PDF 预览页，以及通用 HTTPS PDF 直链，可混合输入。HF 论文页自动转为 arXiv 下载；公开 GitHub 仓库的 PDF 预览页自动转为原始文件链接，与对应 raw 链接去重。最多 200 条/批，自动去重。终端中进度原位更新，每篇只保留简短结果，状态使用颜色；设置 `NO_COLOR=1` 可关闭颜色。重定向 stdout 时输出成功文件的绝对路径；`--json` 始终输出无颜色的 schema 1 批次对象。进度与错误写入 stderr。Ctrl+C 取消并清理临时文件，完成的 PDF 保留。

颜色只强调操作状态：进行中为青色、成功为绿色、等待为黄色、失败为红色；错误原因另起一行使用普通文字。进度按当前终端列宽裁切，保留完整中文字符和组合 emoji；极窄窗口或 `TERM=dumb` 使用静态输出，避免换行后残留旧进度。帮助页精简为用法、示例、对齐的选项与默认行为。

```sh
arxiv-download https://mirros.ai/report/agent-garten.pdf
```

通用 PDF 用 ETag / Last-Modified 条件请求检查更新，304 时复用内容未变的本地文件。没有可靠更新标记或发生重定向时重新下载校验；登录网页和 HTML 页面不能作为 PDF 保存。限流只暂停同一输入站点，其余站点可继续下载。

2.2 支持将公开 OpenReview 讨论页、ACL Anthology 论文页和 CVF 论文页转换为 PDF 地址。不同输入来源最多三个并行，同一来源串行；arXiv 的共享请求间隔与限流策略保持不变。混合来源下载使用简短逐项结果，避免进度覆盖；`--json` 的结果保持输入顺序，普通 stdout 路径按完成顺序输出。

退出码：0 全部成功；1 有失败或待重试项；2 参数或目录错误；130 SIGINT 取消；143 SIGTERM 取消。JSON 的结果状态为 saved、existing、failed、paused、cancelled；暂停项可能包含 retryAfter（ISO 8601）。

同一用户的新版 UI 与 CLI 共享请求间隔、冷却及下载锁；等待其他任务时可以取消。macOS 仍可能要求单独授权终端访问文件夹。内置 CLI 随应用一起升级；独立 CLI 请与 UI 同步更新。

当前为 ad-hoc 签名和 Hardened Runtime，未 Apple 公证。macOS 可能拦截首次运行；请确认下载来源，再按系统「隐私与安全性」提示处理。
