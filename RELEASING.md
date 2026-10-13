# 构建与发布

面向 Apple Silicon / macOS 13+。普通用户从 [Releases](https://github.com/cleardusk/folioak/releases/latest) 安装，无需开发工具；开发环境见 [CONTRIBUTING](CONTRIBUTING.md)。

## 本地检查

```sh
./test.command --stress
./package.command
```

首次运行会下载并校验固定版本的媒体依赖，后续复用 `build/media-tools/`。测试默认不访问真实下载站点；`--live` 会联网，`--snapshots` 输出界面预览。测试使用隔离临时目录，截图等产物输出到 `build/`。

打包产物在 `dist/`：完整内置 CLI 和媒体组件的应用 DMG、应用 ZIP、`SHA256SUMS.txt`。DMG 先生成 HFS+ 只读镜像，再以 4 MiB 压缩块转换为 ULMO（LZMA），让完整媒体组件更有效地压缩，保持 macOS 13 最低要求。不单独发布 CLI 安装包。脚本检查解压后的签名、arm64 架构、版本与 CLI JSON；构建失败不替换已有应用。

依赖版本、源码与哈希由 `Tools/prepare-media.py` 固定。压缩、运行时限制和各组件许可证见 [Media components](Resources/MediaComponents.md)；组件更新需重新验证，不在用户运行时自更新。

## 发布流程

1. 修改 `Resources/Info.plist` 的 `CFBundleShortVersionString`，递增 `CFBundleVersion`。
2. 更新 `.github/release-notes.md`，提交并推送 `main`，等待 Actions 全部通过。
3. 创建与应用版本一致的标签并推送：

```sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
git tag -a "v$version" -m "Folioak $version"
git push origin "v$version"
```

标签触发完整测试、打包和校验，通过后创建 Release；已发布版本不覆盖，修正须发布新版本。普通 `main` 构建保留安装包 artifact 7 天；PR 与手动运行不创建 Release。

仅修改根目录 Markdown、发布说明或 README logo 时跳过 CI；代码、应用资源、构建配置仍触发检查。发版标签和手动运行不受路径过滤影响。

CI 固定 Xcode 26.3 / macOS SDK 26.2，并校验 arm64；最低运行系统仍为 macOS 13。官方 actions 固定到提交，构建仅有读取权限，只有通过检查的标签发布任务可写入 Release。

媒体缓存按工具链、构建脚本和配置精确匹配，不使用回退键；命中后仍校验文件哈希及符号链接。不缓存应用或安装包，缓存丢失可重新构建。

## 本机更新

应用运行期间默认每天检查一次 GitHub 最新正式 Release，使用 ETag 缓存，失败时退避并遵守限流。只提示具有已上传、非空 arm64 DMG 或 ZIP 的正式版本；后台失败不弹窗，手动检查会反馈错误并可打开固定发布页。GitHub 限流时保留冷却时间，自动检查在服务端给出的时间后恢复；不会将共用网络额度耗尽描述为用户操作过于频繁。更新提示仅打开固定仓库的发布页，不下载、执行或替换应用。跳过版本和自动检查开关保存在偏好中，手动检查不受跳过设置影响。可用 `./test.command --updates-only` 验证离线更新逻辑，`./build/CoreTests --updates-live` 额外验证真实 GitHub 接口。

退出应用，备份旧 `.app`、偏好及已有 `workspace.json`、`library.json`、`media-library.json`。核验已发布 ZIP 的 SHA-256、签名和版本后替换 `/Applications/Folioak.app`，启动确认原草稿、目录和资料库保留。不要把 QA 状态带入用户环境。

从旧品牌升级时，将旧应用移入备份，避免同时启动两个共享同一数据域的应用。数据域与文件来源属性继续使用 `local.paperrepo.arxiv-downloader`，这是兼容标识，不随产品名改变。已有保存目录和文件路径保持原样；无保存目录偏好但存在旧默认目录时继续沿用。已有 shell alias 若写死旧 `.app` 路径，需要更新，见 [CLI 说明](CLI-README.md)。

目前为 ad-hoc 签名并启用 Hardened Runtime，尚无 Developer ID 签名或 Apple 公证。公开分发的首次打开仍可能需要用户在系统「隐私与安全性」中允许。
