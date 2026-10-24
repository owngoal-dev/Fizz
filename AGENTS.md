本文件定义本仓库（Lemon）中 AI 协作者的基础工作方式。除非用户明确给出更新指令，后续协作应持续遵守这些规则。

## 交流语言

- 与用户交流时使用简体中文。
- 解释思路、汇报进度、总结结果、询问问题时，都使用简体中文。
- 引用外部 API、系统符号、文件路径、命令、错误码、类名、方法名、常量名时，保留其原文。

## 代码语言

- 编写或修改代码时，代码内容必须使用英语。
- 代码注释必须使用英语。
- 运行时日志、调试日志、错误日志、诊断消息必须使用英语。
- 标识符、文件名、目录名、构建脚本、测试名、提交信息默认使用英语。
- 本地化资源除外；面向用户显示的可本地化文本可以按资源文件的语言要求编写。

## 协作方式

- 每次新会话或重新接手任务时，先读 `docs/README.md`，再按任务触碰范围读取 `docs/LEMON_HOME_GESTURE.md`、`docs/LEMON_BADGE_CLEAR.md`、`docs/LEMON_SETTINGS.md`。
- `docs/archive/` 下的文档是历史归档，只用于追溯先前的决策和证据；如果根目录新文档与归档文档冲突，以根目录新文档为准。
- 保持改动范围清晰，避免把无关重构混入当前任务。
- `references/` 是本地参考快照，不提交；其中 `references/libactivator/` 是 libactivator 的只读副本，只用于查证旧行为，不要修改。
- `Attachments/` 是会话附件，不提交。
- `docs/` 根目录下的新文档使用简体中文编写；普通段落保持一段一行，不要按固定行宽硬换行。
- 新增重要工程约定时，更新本文件或 `docs/` 下对应的文档。
- 遇到不确定的兼容性、越狱布局、IPC、SpringBoard 私有 API 选择时，先记录待决策点，再与用户确认。

## 验证方式

- 完成代码改动后，应尽量运行与改动范围匹配的格式化、构建或测试命令。
- 如果无法验证，应在最终回复中说明原因。
- 验证输出中新增的日志或诊断文本也必须使用英语。

## Lemon 构建与验证

- 本仓库通过 Apelin 的 external 构建工作区构建，入口固定在 `apelin/build.sh`，由 Apelin 的 `build` 工具带 `APELIN_PACKAGE_DIR` 调用；不要引入 Theos，也不要安装 Theos。
- 脚本编译 `lemon/*.m`，再单独编译设置面板（`lemon/prefs/LEMPrefsRootListController.m` 与共享的 `lemon/LEMPreferences.m`，`-bundle -undefined dynamic_lookup`），roothide 只出 `arm64e`，rootless 出 `arm64 arm64e`，最后写出一个 `.deb`。两份 AHAP（`LEMRipple.ahap`、`LEMRippleCleared.ahap`）由脚本拷到 `Library/MobileSubstrate/DynamicLibraries`，运行时就近读取，不编进 dylib。
- 构建通过后按 `build` → `install` → `confirm_loaded`（SpringBoard，需要 respring）的顺序确认加载。自动化只做到这里：手势、角标清空和设置开关的“第一次”效果留给用户手动触发并观察，agent 不为自检主动做会改变设备状态的操作。
- 生产构建只有 `ApelinLoaded` 一行 os_log，没有日志文件，也不再有 postinst；需要临时排查时再加英语 os_log，问题解决后删除。
