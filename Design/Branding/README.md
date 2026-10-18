# Folioak 图标

打开的书页与橡叶呼应 folio / oak；白色 macOS 圆角底板、玉绿实心符号和透明外缘延续品牌辨识。

- [源图](../../Resources/FolioakIcon.png) · [macOS 图标](../../Resources/AppIcon.icns) · [README 标记](../../Resources/FolioakMark.png)
- [原始生成图](Folioak-generated.png) · [image_gen 提示词](folioak-prompt.txt)
- 旧图标及 A/B/C 候选仅作设计存档，不打包。

从仓库根目录生成生产遮罩，清除底板外的透明杂点：

```sh
xcrun swift Tools/MakeIcon.swift Design/Branding/Folioak-generated.png build/Folioak-master.iconset --round-tile
```

1024 px 结果用作源图，512 px 用作 README 标记；日常构建仅缩放源图，保留透明背景。发布前检查 16 / 32 / 64 / 128 px、深浅背景和实际关于窗口。
