# 打包与发布

仓库：<https://github.com/cleardusk/arxiv-download-ui>（private）。源码、Actions 日志与 Releases 仅对有仓库权限的账号开放。

## 在其他 Mac 使用

登录 GitHub，打开 [Releases](https://github.com/cleardusk/arxiv-download-ui/releases)，下载最新的 DMG 安装包，打开后将应用拖入 Applications。也可下载 ZIP，解压后拖入 Applications。支持 Apple Silicon（M 系列芯片），最低 macOS 13；首次启动后选择当前电脑的保存目录。无需安装开发工具。

当前为 ad-hoc 签名，开启 Hardened Runtime，但没有 Apple Developer ID 或公证。macOS 首次打开可能拦截；确认来源后在「系统设置 → 隐私与安全性」允许打开。后续若需顺畅分发，应单独配置 Developer ID 与公证凭据；DMG 不替代签名、公证。

## 本地打包

需要 Apple Command Line Tools 或 Xcode，以及 Python 3（仅构建使用）。首次构建会下载固定版本并校验 SHA-256，构建 FFmpeg 后缓存到 `build/media-tools/`：

```sh
python3 Tools/prepare-media.py # 首次准备；后续校验并复用缓存
./test.command --stress
./package.command
```

`package.command` 构建含 CLI 和媒体组件的 arm64 `Leafpick.app`，先签名内置组件、CLI，再签名完整应用；验证解压后的签名、架构、CLI 版本及 JSON，并确认内置和独立 CLI 相同。生成 `Leafpick-v版本-macos-arm64.dmg` / `.zip`、`leafpick-cli-v版本-macos-arm64.zip` 和 SHA-256 校验文件，输出到 `dist/`。构建失败不会替换已有 `.app`。

yt-dlp、Deno、FFmpeg 的版本、源码和校验值在 `Tools/prepare-media.py`，许可说明在 `Resources/MediaComponents.md`。Deno 仅有其 JS 运行所需的 JIT entitlement；PyInstaller yt-dlp 仅有加载内嵌 Python 所需的 library-validation entitlement。应用主程序不继承这些例外。组件更新必须修改固定版本／校验值并重新验证，不在用户运行时自更新。

`test.command` 还支持 `--stress`（200 次模拟下载及释放检查）、`--live`（真实下载至 `build/live-UUID/`）和 `--snapshots`（界面预览输出至 `build/qa/`）。离线检查包含 CLI 退出码、信号取消和独立进程协调；真实下载测试不写入 PapersRepo。

## 提交规范

采用 [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)：`type(scope): description`，scope 可省略。功能用 `feat`，修复用 `fix`，文档用 `docs`，构建脚本用 `build`，工作流用 `ci`；例如 `fix(download): handle expired links` 或 `docs: simplify README`。破坏性变更使用 `!` 或 `BREAKING CHANGE:` 标注。

## 发布新版本

1. 修改 `Resources/Info.plist` 中的 `CFBundleShortVersionString`（如 `1.2.0`），同时递增 `CFBundleVersion`。
2. 更新 `.github/release-notes.md`，提交并推送 `main`，等待 Actions 回归与构建全部通过。
3. 创建与应用版本一致的 tag 并推送：

```sh
git tag -a v1.2.0 -m 'Leafpick 1.2.0'
git push origin v1.2.0
```

Actions 会再次执行离线／资源测试，构建安装包，核验包的 SHA-256 后创建 Release，附上 UI DMG / ZIP、CLI ZIP、校验文件。任一检查失败都不会发布；tag 与应用版本不一致会失败。已发布的版本不会自动覆盖，修正内容应发布新版本。

更新本机 `/Applications` 前，退出应用，备份旧 `.app`、偏好设置、`workspace.json` 及存在的 `library.json`、`media-library.json`。核验已发布 ZIP 的校验和、签名、版本和内置 CLI 后再替换；首次启动检查旧任务、草稿与独立资料库迁移，避免使用测试数据覆盖用户状态。

普通 `main` 推送会测试、构建并保留安装包 artifact 7 天；PR 只测试、构建。在 Actions 页面手动运行也可获取安装包，手动运行不创建 Release。自动测试不访问 arXiv，以免真实服务故障影响发布。

云端使用固定提交的 `actions/cache` 缓存 `build/media-tools/`，包含媒体可执行文件、校验清单和许可文件。缓存键包含系统／架构、Xcode／SDK，以及 `Tools/prepare-media.py` 和媒体说明的内容哈希；普通 UI 改动和应用版本号不使缓存失效。`main` 成功构建产生的缓存可供之后的版本标签复用，详见 [GitHub 缓存作用域](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache)。

不使用跨版本回退键。缓存命中后仍由准备脚本逐个校验二进制 SHA-256，应用的签名与安装包校验照常执行。首次构建、组件／编译配置／工具链变化、媒体二进制校验不符或缓存被 GitHub 清理时会重新构建；长期保留缓存不是发布的前提。仅缓存组件，不缓存 `.app` 或已签名的安装包。

云端固定使用 Xcode 26.3 / macOS SDK 26.2，避免默认旧 SDK 改变新系统上的原生控件外观；最低系统版本仍为 macOS 13。该工具链来自 [GitHub 官方 macOS runner 镜像](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)，缺失或版本不符时构建直接失败。

工作流只使用固定提交版本的 GitHub 官方 actions。测试、构建任务只有只读仓库权限；仅通过全部检查的 tag 发布任务获得写入 Release 的权限，无需额外上传个人 GitHub token。Apple 签名凭据未配置。

私有仓库的 macOS Actions 消耗账号的构建额度，超出免费额度后的运行受账号计费设置约束；本工作流构建设置 15 分钟超时，同分支的新提交取消旧运行，tag 发布保留独立运行。
