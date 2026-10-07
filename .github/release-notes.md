本版调整：

- 窗口顶部与主题背景融为一体，标题和设置入口集中在顶部，保留原生窗口控制。
- 打开保存目录改为「打开」，避免与选择目录使用相同图标。
- 文件名清理保留组合 emoji；补充特殊字符、Unicode、长标题和不可写目录的实际保存测试。

- 支持 Apple Silicon（M 系列芯片），最低 macOS 13。

下载 DMG 安装包，打开后将「arXiv 下载器」拖入 Applications；也可下载 ZIP 解压后安装。启动后选择本机保存目录，无需安装 Xcode、Python 或 Node。

当前使用 ad-hoc 签名和 Hardened Runtime，尚未使用 Developer ID 签名或 Apple 公证。macOS 首次打开可能拦截；确认来源后，可在「系统设置 → 隐私与安全性」中允许打开。私有仓库的安装包需要登录有仓库访问权限的 GitHub 账号才能下载。

`SHA256SUMS.txt` 提供两个安装包的校验值。
