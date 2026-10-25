# Fizz 设置面板

## 入口

设置面板走 PreferenceLoader，打包成两个部件：

- `$PREFIX/Library/PreferenceLoader/Preferences/Fizz.plist`：设置首页里名为“Fizz”的入口，`cell` 是 `PSLinkCell`，`detail` 指向 `FIZZPrefsRootListController`。
- `$PREFIX/Library/PreferenceBundles/FizzPrefs.bundle`：真正的面板，`Info.plist` 的 `NSPrincipalClass` 是 `FIZZPrefsRootListController`，可执行文件由 `fizz/prefs/FIZZPrefsRootListController.m` 和共享的 `fizz/FIZZPreferences.m` 编译而来（`apelin/build.sh` 单独用 `-bundle -undefined dynamic_lookup` 编译，不链接 `Preferences.framework`）。

面板安装后，Settings 进程要重新启动一次才会载入新 bundle；已经打开的面板会继续用内存里的旧二进制。

## 三个开关

面板只有三个开关，都写在 `com.fizz.ripple` 域里，默认都是打开（没写过值时读取回退到 `YES`）：

| 分组 | 标题 | 键 | 作用 |
| --- | --- | --- | --- |
| 手势 | 启用 | `Enabled` | 全局开关。关闭后双指外扩手势直接忽略，触感、角标清空和气泡淡出也一起停掉。 |
| 手势 | 触感反馈 | `Haptics` | 图标落回原位那一刻震一下：没有角标可清时是 `Light` 轻响，有角标、气泡炸掉时是 `Heavy` 重响；关闭后只做涟漪与清空，不震动。 |
| 角标 | 角标维持 | `KeepCleared` | 抑制层开关。App 打开或退到后台时会重新上报角标；打开本项时，与已清除数字相同的旧值被忽略，新数字照常显示。关闭后手势照样清空角标并让气泡淡出，但不再拦截任何上报，旧数字会随 App 回来。 |

三个开关都即时生效，不需要 respring：手势在 `Began` 时读一次全局开关，播放触感前读一次“触感反馈”；`FIZZBadgeClearAll()` 进入时读一次全局开关；抑制层在记录基线（`FIZZBadgeRecordBaseline`）和判断某次写入是否丢弃（`FIZZBadgeShouldSuppressWrite`）时各读一次“角标维持”。“触感反馈”只决定震不震动，“角标维持”不影响清空本身，也不影响气泡淡出。读取直接走 `CFPreferences`，cfprefsd 在面板保存后会把新值交给 SpringBoard，因此不需要额外注册 Darwin 通知。

App 打开会取回自己的角标数字，退到后台时又会把这个数字重新上报一次，所以清空之后它们仍会尝试把旧值写回来，这也是“角标维持”存在的理由。打开“角标维持”时，与清除前完全相同的值被丢弃，App 真有新消息、或者用户把消息读完导致的数字变化都照常生效；关闭“角标维持”时不再写新的基线，已经清掉的角标不会因此回来，但 App 下一次上报的数字会直接显示出来。重新打开时恢复记录，抑制表里的旧记录继续生效。

## 文案

- 分组“手势” footer：双指外扩清除所有角标。
- 开关“启用”。
- 开关“触感反馈”。
- 分组“角标” footer：App 打开或退到后台时仍会重新上报角标。打开本项后，与已清除数字相同的旧值会被忽略，新数字照常显示；关闭后旧数字可能再次出现。
- 开关“角标维持”，键仍是 `KeepCleared`，改名不改键，已保存的设置不受影响。

## 实现要点

- 面板是 `PSListController` 的子类，specifier 全部在代码里构造，没有 `Root.plist`：两个 `groupSpecifierWithName:` 分组（带 `footerText`）加三个 `PSSwitchCell`（PSCellType 6）。
- specifier 的 target 是控制器自身，set/get 走 `-setPreferenceValue:specifier:` 与 `-readPreferenceValue:`；写值用 `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize` 落到 `com.fizz.ripple`，读值复用 `FIZZPreferencesGetBool`，域和键只定义一次。
- `Preferences.framework` 没有公开头文件，`PSListController`、`PSSpecifier` 的方法和 `PSSwitchCell` 常量都在这个 `.m` 里自行声明。关键是 `PSListController` 的 `_specifiers` ivar：表格渲染的是这个数组，子类必须把行写进它，而不是自己另开一个 ivar。声明里带上 `_specifiers` 后，编译器引用 `_OBJC_IVAR_$_PSListController._specifiers` 这个外部符号，由 Preferences 在加载时绑定；本机其他第三方面板（`DonutPrefs`、`HelloMemoryStatusPrefs`、`hello120hz`）用的是同一套写法。
- 只写自己的 `_ownSpecifiers` 也能编译、面板标题也能出现，但表格永远零行，设置里看到的就是一个空列表。
