# leafpick CLI

随 [Leafpeak](README.zh-CN.md) 内置，无需启动界面或单独安装。

```sh
alias leafpick='"/Applications/Leafpeak.app/Contents/MacOS/leafpick"'

leafpick 1706.03762                   # 下载论文
leafpick 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
leafpick --audio 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
leafpick -i links.txt                 # 批量下载
leafpick 1706.03762 -o ~/Downloads/Papers
leafpick --help                       # 全部选项
```

默认沿用应用的保存位置，按类型归档。`-o` 直接保存到指定目录，不添加子文件夹；同名文件不会被覆盖。

支持公开论文和媒体链接；站点范围与限制见 [README](README.zh-CN.md)。按 `Ctrl+C` 停止下载，已完成的文件保留。旧命令 `arxiv-download` 仍可使用。

用于脚本：`cat links.txt | leafpick --json`。进度写入 stderr；退出码 `0` 成功，`1` 有失败或待重试，`2` 参数错误，`130` 用户取消，`143` 终止。
