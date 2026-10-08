统一 UI 与 CLI 的安装体验，并精简终端输出。

- DMG / 应用 ZIP 内置 `arxiv-download`，拖入 Applications 即同时安装 UI 和 CLI，内置 CLI 随应用升级。
- 终端中一行更新进度，每篇结束只保留简短结果；成功、等待重试、失败使用不同状态颜色，支持 `NO_COLOR`。
- 重定向 stdout 保留完整文件路径，`--json` 保持无颜色的结构化输出；普通文本保留 Unicode 文件名。
- UI 与内置、独立 CLI 使用同一个下载核心、默认目录、命名和跨进程限流。
- 加强内置 CLI 的签名、架构、版本、JSON 与独立可执行文件一致性检查。

支持 Apple Silicon，最低 macOS 13。下载 DMG，将应用拖入 Applications 后，终端运行：

```sh
"/Applications/arXiv下载器.app/Contents/MacOS/arxiv-download" --help
```

仅使用 CLI 也可选择独立 CLI ZIP。私有仓库需要登录有访问权限的 GitHub 账号。

当前为 ad-hoc 签名和 Hardened Runtime，尚未 Apple 公证。首次打开可能需在「系统设置 → 隐私与安全性」允许打开。

应用遵守服务端限流，不保证 arXiv 始终可用。SHA256SUMS.txt 包含三个安装包的校验值。
