# 文档入口

本目录保存 Lemon 的当前结论；`docs/archive/` 是历史归档，只用于追溯当时的证据和旧版本，如果根目录文档与归档文档冲突，以根目录文档为准。

## 文档

- `LEMON_HOME_GESTURE.md`：主屏双指手势的接入方式、与 `SBIconScrollView` 内置 pan 的冲突处理、图标涟漪参数与 hooks。
- `LEMON_BADGE_CLEAR.md`：徽章清除的逆向结论、四层实现、抑制表与待验证项。
- `LEMON_SETTINGS.md`：设置面板的入口、两个开关的键与即时生效方式。
- `archive/2026-10-24/reverse-engineering/`：旧徽章 inspector 快照，只用于追溯，不参与编译。

## 更新规则

根目录文档只记录会影响后续实现决策的当前结论。临时调查过程、一次性 probe 输出、过时计划和长证据链不要塞回根目录；需要保存时放到 `docs/archive/`。

`docs/` 目录下的普通段落不要按固定行宽硬换行。文档正文使用简体中文；API 名称、命令、状态值、文件路径、类名、方法名、常量名保持原文。
