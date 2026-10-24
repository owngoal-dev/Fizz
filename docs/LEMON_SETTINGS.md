# Lemon 设置面板

## 入口

设置面板走 PreferenceLoader，打包成两个部件：

- `$PREFIX/Library/PreferenceLoader/Preferences/Lemon.plist`：设置首页里名为“Lemon”的入口，`cell` 是 `PSLinkCell`，`detail` 指向 `LEMPrefsRootListController`。
- `$PREFIX/Library/PreferenceBundles/LemonPrefs.bundle`：真正的面板，`Info.plist` 的 `NSPrincipalClass` 是 `LEMPrefsRootListController`，可执行文件由 `lemon/prefs/LEMPrefsRootListController.m` 和共享的 `lemon/LEMPreferences.m` 编译而来（`apelin/build.sh` 单独用 `-bundle -undefined dynamic_lookup` 编译，不链接 `Preferences.framework`）。

面板安装后，Settings 进程要重新启动一次才会载入新 bundle；已经打开的面板会继续用内存里的旧二进制。

## 两个开关

面板只有两个开关，都写在 `com.lemon.ripple` 域里，默认都是打开（没写过值时读取回退到 `YES`）：

| 分组 | 标题 | 键 | 作用 |
| --- | --- | --- | --- |
| 手势 | 启用 | `Enabled` | 全局开关。关闭后双指外扩手势直接忽略，角标清空和淡出也一起停掉。 |
| 角标 | 保持清空 | `KeepCleared` | 抑制层开关。关闭后手势照样清空角标并淡出，但不再拦截 App 重推的旧数字，角标会随 App 上报回来。 |

两个开关都即时生效，不需要 respring：手势在 `Began` 时读一次全局开关；`LEMBadgeClearAll()` 进入时读一次全局开关；抑制层在记录基线（`LEMBadgeRecordBaseline`）和判断某次写入是否丢弃（`LEMBadgeShouldSuppressWrite`）时各读一次“保持清空”。“保持清空”不影响清空本身，也不影响淡出。读取直接走 `CFPreferences`，cfprefsd 在面板保存后会把新值交给 SpringBoard，因此不需要额外注册 Darwin 通知。

关闭“保持清空”时不再写新的基线，已经清掉的角标也不会因此回来；App 下次上报数字时徽章照常出现。打开时重新开始记录，抑制表里的旧记录继续生效。

## 文案

- 分组“手势” footer：主屏幕双指外扩：图标向外扩散，同时清除所有角标。关闭后手势不再响应。
- 开关“启用”。
- 分组“角标” footer：打开时忽略 App 重新上报的旧角标；关闭后旧数字可能再次出现。
- 开关“保持清空”。

## 实现要点

- 面板是 `PSListController` 的子类，specifier 全部在代码里构造，没有 `Root.plist`：两个 `groupSpecifierWithName:` 分组（带 `footerText`）加两个 `PSSwitchCell`（PSCellType 6）。
- specifier 的 target 是控制器自身，set/get 走 `-setPreferenceValue:specifier:` 与 `-readPreferenceValue:`；写值用 `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize` 落到 `com.lemon.ripple`，读值复用 `LEMPreferencesGetBool`，域和键只定义一次。
- `Preferences.framework` 没有公开头文件，`PSListController`、`PSSpecifier` 的方法和 `PSSwitchCell` 常量都在这个 `.m` 里自行声明。关键是 `PSListController` 的 `_specifiers` ivar：表格渲染的是这个数组，子类必须把行写进它，而不是自己另开一个 ivar。声明里带上 `_specifiers` 后，编译器引用 `_OBJC_IVAR_$_PSListController._specifiers` 这个外部符号，由 Preferences 在加载时绑定；本机其他第三方面板（`DonutPrefs`、`HelloMemoryStatusPrefs`、`hello120hz`）用的是同一套写法。
- 只写自己的 `_lemonSpecifiers` 也能编译、面板标题也能出现，但表格永远零行，设置里看到的就是一个空列表。
