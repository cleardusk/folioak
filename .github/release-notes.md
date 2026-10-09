arXiv下载器 2.0.2：直接粘贴 Hugging Face 论文页下载。

- UI 与 CLI 支持 `https://huggingface.co/papers/编号`，自动转为 arXiv 下载，无需额外访问 HF 网页。
- 支持 `hf.co` 短域名、版本号、尾部斜杠和分享参数，与相同 arXiv 链接／编号自动去重。
- 兼容旧版本保存的 HF 失败任务，升级后重试使用 arXiv 下载流程，保留原有队列、资料库和日志。
- 沿用既有命名、限流、重试和本地文件复用，保持界面简洁。

支持 Apple Silicon，最低 macOS 13。DMG / 应用 ZIP 内置 CLI，另外提供独立 CLI ZIP 和 SHA-256 校验文件。

当前采用 ad-hoc 签名和 Hardened Runtime，尚未 Apple 公证。
