Folioak 2.4.0

- 产品与仓库统一更名为 Folioak，应用、命令行、安装包和文档同步更新；新图标以书页与橡叶呼应名称。
- 设置 → 通用新增语言：跟随系统、简体中文、English。切换立即生效，保留输入、选择与已有资料内容。
- 命令行入口改为 `folioak`；包内保留 `leafpick` 和 `arxiv-download` 兼容入口。已有 shell alias 若指向旧应用路径，请改为 `/Applications/Folioak.app/Contents/MacOS/folioak`。

支持 Apple Silicon、macOS 13 及以上。媒体组件完整内置。升级时退出旧应用，将 Folioak.app 放入 Applications 并移走旧版应用；偏好、保存目录、草稿、下载记录与资料库继续沿用，已有文件不移动。全新安装默认保存到 ~/Downloads/Folioak。
