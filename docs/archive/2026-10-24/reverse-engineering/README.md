# 旧徽章探针快照

本目录保存 2026-10-24 清理前的徽章 inspector（`LEMBadgeInspector.{h,m}`）快照，只用于追溯当时的 dump 代码和字段探测方式。

`LEMBadgeInspector.{h,m}` 依赖已经删除的完整日志接口（`LEMLog`、`LEMLogSetup` 等），**不参与编译**，也不能直接拷回 `lemon/` 使用。其中的逆向结论已经整理进 `docs/LEMON_BADGE_CLEAR.md`；需要重新排查时，应基于当前 `lemon/` 的最小日志标记重新写临时诊断，不要长期保留。
