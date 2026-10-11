# folioak CLI

随 [Folioak](README.zh-CN.md) 内置，无需启动界面或单独安装。

```sh
alias folioak='"/Applications/Folioak.app/Contents/MacOS/folioak"'

folioak 1706.03762                   # 下载论文
folioak 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
folioak --audio 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
folioak -i links.txt                 # 批量下载
folioak 1706.03762 -o ~/Downloads/Papers
folioak --help                       # 全部选项
```

默认沿用应用的保存位置，按类型归档。`-o` 直接保存到指定目录，不添加子文件夹；同名文件不会被覆盖。

支持公开论文和媒体链接；站点范围与限制见 [README](README.zh-CN.md)。按 `Ctrl+C` 停止下载，已完成的文件保留。包内保留 `leafpick` 和 `arxiv-download` 兼容入口；若曾设置指向旧应用路径的 shell alias，请按上面的示例更新。

用于脚本：`cat links.txt | folioak --json`。进度写入 stderr；退出码 `0` 成功，`1` 有失败或待重试，`2` 参数错误，`130` 用户取消，`143` 终止。
