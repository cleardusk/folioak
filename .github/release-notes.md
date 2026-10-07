原生 macOS 论文下载工具：粘贴一个或多个 arXiv 链接，自动获取标题、命名并保存 PDF。

- 六套主题、深浅外观与保存目录／命名设置。
- 明确版本下载、同批去重、同名不覆盖、失败重试与取消。
- 支持 Apple Silicon（M 系列芯片），最低 macOS 13。

下载 `macos-arm64.dmg`，打开后将「arXiv 下载器」拖入 Applications；也可下载 ZIP 解压后安装。启动后选择本机保存目录，无需安装 Xcode、Python 或 Node。

当前使用 ad-hoc 签名和 Hardened Runtime，尚未使用 Developer ID 签名或 Apple 公证。macOS 首次打开可能拦截；确认来源后，可在「系统设置 → 隐私与安全性」中允许打开。私有仓库的安装包需要登录有仓库访问权限的 GitHub 账号才能下载。

`SHA256SUMS.txt` 提供两个安装包的校验值。
