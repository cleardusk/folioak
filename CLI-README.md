# folioak CLI

随 [Folioak](README.zh-CN.md) 内置，无需启动界面或单独安装。支持范围与站点限制同应用，但 CLI 始终匿名下载，不读取浏览器认证设置。

```sh
alias folioak='"/Applications/Folioak.app/Contents/MacOS/folioak"'

folioak 1706.03762                    # 下载论文
folioak 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
folioak --audio 'https://www.youtube.com/watch?v=jNQXAC9IVRw' # 仅音频（M4A）
folioak -i links.txt                  # 批量下载
folioak 1706.03762 -o ~/Downloads/Papers
cat links.txt | folioak --json        # 脚本使用
folioak --help                       # 全部选项
```

- **保存位置**：默认沿用应用目录、按类型归档，也遵守独立 PDF 目录设置。`-o` / `--output` 优先指定本次所有文件的目录，不追加子文件夹、不修改应用设置，也不覆盖已有文件。
- **命名**：沿用应用各类型规则；`--naming date-title|id-title|title` 仅在本次运行覆盖 arXiv 规则。
- **停止与输出**：`Ctrl+C` 停止，已完成文件保留。进度写入 stderr；退出码为 `0` 成功、`1` 有失败或待重试、`2` 参数错误、`130` 用户取消、`143` 终止。
- **旧版兼容**：包内保留 `leafpick` 和 `arxiv-download` 入口；指向旧应用路径的 shell alias 需按上例更新。
