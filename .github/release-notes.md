arXiv下载器 2.0.3：直接粘贴 GitHub PDF 预览链接下载。

- UI 与 CLI 自动将公开 GitHub 仓库的 `.pdf` 预览链接转为 raw 原始文件链接，无需访问预览页。
- 保留分支／标签／提交、子目录及编码后的文件名；预览参数和页码不影响去重。
- 预览链接和对应 raw 链接自动去重，共用本地缓存和更新检查。
- 兼容旧版本保存的 GitHub 失败任务，升级后可直接重试，保留原有队列、资料库和日志。

支持 Apple Silicon，最低 macOS 13。DMG / 应用 ZIP 内置 CLI，另外提供独立 CLI ZIP 和 SHA-256 校验文件。

当前采用 ad-hoc 签名和 Hardened Runtime，尚未 Apple 公证。
