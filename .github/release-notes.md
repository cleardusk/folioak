支持通用 HTTPS PDF 直链，UI 和 CLI 均可与 arXiv 链接混合使用。

- 通用 PDF 使用文档标题或原文件名；arXiv 保留日期、标题及版本命名。
- 内容验证、文件去重、取消、重试和原子保存共用下载核心，不覆盖已有文件。
- 通用 PDF 通过 ETag / Last-Modified 检查更新，304 时复用完整本地文件；不把不同重定向资源的更新标记混用。
- 增加 HTTPS、公共地址、DNS 预检和重定向检查；保留 arXiv 白名单。拒绝 HTML、非完整响应和无效 PDF。
- DMG 同时包含 UI 和 CLI，配置继续共享。终端保持精简输出及状态颜色。

安装后可直接运行：

```sh
"/Applications/arXiv下载器.app/Contents/MacOS/arxiv-download" https://mirros.ai/report/agent-garten.pdf
```

支持 Apple Silicon，最低 macOS 13。私有仓库需要登录有访问权限的 GitHub 账号。

当前为 ad-hoc 签名和 Hardened Runtime，尚未 Apple 公证。首次打开可能需在「系统设置 → 隐私与安全性」允许打开。

仅支持公开 HTTPS PDF 直链；需要登录的页面不受支持。应用遵守服务端限流，SHA256SUMS.txt 包含三个安装包的校验值。
