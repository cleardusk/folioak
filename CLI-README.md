# arxiv-download

Apple Silicon / macOS 13+ 命令行论文下载工具，无需启动 UI。

解压 CLI ZIP，在解压后的目录运行 `./arxiv-download --help`。如需直接使用命令名，可将可执行文件放入 PATH 中的个人 bin 目录。

```sh
./arxiv-download https://arxiv.org/html/2605.18678 -o ~/Downloads/Papers
./arxiv-download 1706.03762v1 2609.22978v1 --naming id-title --json
```

默认使用 UI 中的保存目录与命名方式。`-o` 和 `--naming` 仅影响本次执行，不修改设置；显式 `-o` 的目录不存在时会创建。命名可选 `date-title`、`id-title`、`title`。自动化脚本建议显式指定目录和命名方式。

支持摘要、PDF、HTML 链接或编号，最多 200 条/批，自动去重。普通 stdout 输出成功文件的绝对路径；`--json` 输出 schema 1 的单个批次对象。进度与错误写入 stderr。Ctrl+C 取消并清理临时文件，完成的 PDF 保留。

退出码：0 全部成功；1 有失败或待重试项；2 参数或目录错误；130 SIGINT 取消；143 SIGTERM 取消。JSON 的结果状态为 saved、existing、failed、paused、cancelled；暂停项可能包含 retryAfter（ISO 8601）。

同一用户的新版 UI 与 CLI 共享请求间隔、冷却及下载锁；等待其他任务时可以取消。系统文件夹权限仍由 macOS 分别检查，CLI 不会继承 UI 的授权。请同时升级两个入口。

当前为 ad-hoc 签名和 Hardened Runtime，未 Apple 公证。macOS 可能拦截首次运行；请确认下载来源，再按系统「隐私与安全性」提示处理。
