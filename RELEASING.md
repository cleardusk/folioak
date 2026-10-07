# 打包与发布

仓库：<https://github.com/cleardusk/arxiv-download-ui>（private）。源码、Actions 日志与 Releases 仅对有仓库权限的账号开放。

## 在其他 Mac 使用

登录 GitHub，打开 [Releases](https://github.com/cleardusk/arxiv-download-ui/releases)，下载最新的 DMG 安装包，打开后将应用拖入 Applications。也可下载 ZIP，解压后拖入 Applications。支持 Apple Silicon（M 系列芯片），最低 macOS 13；首次启动后选择当前电脑的保存目录。无需安装开发工具。

当前为 ad-hoc 签名，开启 Hardened Runtime，但没有 Apple Developer ID 或公证。macOS 首次打开可能拦截；确认来源后在「系统设置 → 隐私与安全性」允许打开。后续若需顺畅分发，应单独配置 Developer ID 与公证凭据；DMG 不替代签名、公证。

## 本地打包

需要 Apple Command Line Tools 或 Xcode：

```sh
./test.command --stress
./package.command
```

`package.command` 构建 arm64 `.app`，验证签名与 ZIP 解压后的架构，再生成 DMG、ZIP 和 SHA-256 校验文件，输出到 `dist/`。构建失败不会替换已有 `.app`。

`test.command` 还支持 `--stress`（200 次模拟下载及释放检查）、`--live`（真实下载至 `build/live-UUID/`）和 `--snapshots`（界面预览输出至 `build/qa/`）。真实下载测试不写入 PapersRepo。

## 提交规范

采用 [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)：`type(scope): description`，scope 可省略。功能用 `feat`，修复用 `fix`，文档用 `docs`，构建脚本用 `build`，工作流用 `ci`；例如 `fix(download): handle expired links` 或 `docs: simplify README`。破坏性变更使用 `!` 或 `BREAKING CHANGE:` 标注。

## 发布新版本

1. 修改 `Resources/Info.plist` 中的 `CFBundleShortVersionString`（如 `1.1.5`），同时递增 `CFBundleVersion`。
2. 更新 `.github/release-notes.md`，提交并推送 `main`，等待 Actions 回归与构建全部通过。
3. 创建与应用版本一致的 tag 并推送：

```sh
git tag -a v1.1.5 -m 'arXiv下载器 1.1.5'
git push origin v1.1.5
```

Actions 会再次执行离线／资源测试，构建安装包，核验包的 SHA-256 后创建 Release，附上 DMG、ZIP、校验文件。任一检查失败都不会发布；tag 与应用版本不一致会失败。已发布的版本不会自动覆盖，修正内容应发布新版本。

普通 `main` 推送和 PR 只测试、构建；在 Actions 页面手动运行也可获取保留 7 天的安装包 artifact，手动运行不创建 Release。自动测试不访问 arXiv，以免真实服务故障影响发布。

工作流只使用固定提交版本的 GitHub 官方 actions。测试、构建任务只有只读仓库权限；仅通过全部检查的 tag 发布任务获得写入 Release 的权限，无需额外上传个人 GitHub token。Apple 签名凭据未配置。

私有仓库的 macOS Actions 消耗账号的构建额度，超出免费额度后的运行受账号计费设置约束；本工作流构建设置 15 分钟超时，同分支的新提交取消旧运行，tag 发布保留独立运行。
