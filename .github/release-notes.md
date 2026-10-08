精简重复实现，保持现有界面、功能和下载逻辑。

- 合并网络请求、文件记录及菜单构建中的重复代码；保留原有校验、取消和资源释放行为。
- 原有回归测试、200 轮资源压力测试通过；66 张静态界面对比一致，菜单行为一致。
- 实测通用 PDF 与 arXiv 混合下载、文件命名及重复下载复用。
- DMG 继续内置 CLI，UI 与 CLI 共用配置；支持 arXiv 和公开 HTTPS PDF 直链。

安装后可直接运行：

```sh
"/Applications/arXiv下载器.app/Contents/MacOS/arxiv-download" https://mirros.ai/report/agent-garten.pdf
```

支持 Apple Silicon，最低 macOS 13。私有仓库需要登录有访问权限的 GitHub 账号。

当前为 ad-hoc 签名和 Hardened Runtime，尚未 Apple 公证。首次打开可能需在「系统设置 → 隐私与安全性」允许打开。

仅支持公开 HTTPS PDF 直链；需要登录的页面不受支持。应用遵守服务端限流，SHA256SUMS.txt 包含三个安装包的校验值。
