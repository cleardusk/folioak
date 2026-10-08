新增独立命令行入口 `arxiv-download`，UI 和 CLI 使用同一个下载核心。

- 支持一个或多个 arXiv 摘要、PDF、HTML 链接或编号，自动去重。
- 默认读取 UI 的保存目录与命名方式；`-o`、`--naming` 仅影响本次执行。
- 普通输出提供文件路径，`--json` 提供批次结果；进度和错误写入 stderr。
- 支持 Ctrl+C / SIGTERM 取消，清理临时文件并保留已完成 PDF。
- 新版 UI 与 CLI 共用下载锁、请求间隔及冷却期，多个进程不会同时发起下载；等待可取消。请同时升级两个入口。
- 增加真实 CLI 进程、跨进程配置、限流、锁释放及信号取消回归。

支持 Apple Silicon，最低 macOS 13。UI 下载 DMG 或 UI ZIP；终端用户下载 `arxiv-download-cli` ZIP，解压后运行 `./arxiv-download --help`，无需安装 UI。私有仓库需要登录有访问权限的 GitHub 账号。

当前为 ad-hoc 签名和 Hardened Runtime，尚未 Apple 公证。首次打开可能需在「系统设置 → 隐私与安全性」允许打开。

应用遵守服务端限流，不保证 arXiv 始终可用。SHA256SUMS.txt 包含三个安装包的校验值。
