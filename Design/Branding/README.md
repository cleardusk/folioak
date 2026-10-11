# Folioak 图标

2.4.0 的图标随产品改名调整为「打开的书页 + 橡叶」，对应 folio 与 oak，也延续原有玉绿色品牌。

参考锁定：原图的白色 macOS 圆角底板、玉绿实心符号、中心构图与透明外缘为主；Refero 的 Icons & Glyphs Guide 提供小尺寸辨识、视觉重量和光学校正规则。在线 Refero 样式库不可用，未借用其他品牌图标。

| 决策 | 来源与用途 |
| --- | --- |
| 保留白色底板和玉绿符号 | 现有应用图标，延续辨识 |
| 书页与五瓣橡叶 | 用户选定的 Folioak 名称，表达本地资料收藏 |
| 宽负空间、少量实心形状 | 图标规范，保证 16 / 32 px 可读性 |
| 透明外缘、轻微中性边缘 | 现有 macOS 图标轮廓，保持深浅背景兼容 |

- 当前源图：../../Resources/FolioakIcon.png
- macOS 图标：../../Resources/AppIcon.icns
- README 图标：../../Resources/FolioakMark.png
- 生成方式：内置 image_gen；最终提示词见 [folioak-prompt.txt](folioak-prompt.txt)。
- 旧版图标与提示词：Leaf-tray-v233.png、leaf-tray-prompt.txt，作为设计存档，不打包。
- 最初深绿版本：Original-leaf-tray.png（设计存档，不打包）
- A/B/C 是未采用的候选，不用于发布。

原始生成结果保存在 Folioak-generated.png。使用 `xcrun swift Tools/MakeIcon.swift Design/Branding/Folioak-generated.png build/Folioak-master.iconset --round-tile` 的生产遮罩去除底板外的透明杂点，图案保持原样；将 1024 px 结果作为源图，512 px 结果用于 README。日常构建仅缩放源图，保留透明背景。发布前检查 16 / 32 / 64 / 128 px、深浅背景及实际关于窗口。
