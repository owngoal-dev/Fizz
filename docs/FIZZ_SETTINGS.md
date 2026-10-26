# Fizz 设置面板

## 入口

设置面板走 PreferenceLoader，打包成两个部件：

- `$PREFIX/Library/PreferenceLoader/Preferences/Fizz.plist`：设置首页里名为“Fizz”的入口，`cell` 是 `PSLinkCell`，`detail` 指向 `FIZZPrefsRootListController`。
- `$PREFIX/Library/PreferenceBundles/FizzPrefs.bundle`：真正的面板，`Info.plist` 的 `NSPrincipalClass` 是 `FIZZPrefsRootListController`，可执行文件由 `fizz/prefs/FIZZPrefsRootListController.m` 和共享的 `fizz/FIZZPreferences.m` 编译而来（`apelin/build.sh` 单独用 `-bundle -undefined dynamic_lookup` 编译，不链接 `Preferences.framework`）。

面板只在被打开时载入 bundle，所以只改面板只需重装再重新进入这个面板，不需要注销或重启 Settings；已经打开着的面板会继续用内存里的旧二进制，关掉再进即可。

## 面板外观

表格顶部有一个 banner（`FIZZBannerView`），挂在 `tableHeaderView` 上，因此随列表滚走、不遮挡内容，高度由内部尺寸算出为 `FIZZBannerHeight = 146`（上 12 + 卡片 128 + 下 6）：

- 卡片左右各留 16，圆角 18（continuous），1 像素描边；卡片内从上到下：16 上留白、图标 50、间隔 12、分隔线 1、间隔 9、开关行 31（正好是 `UISwitch` 的高度）、9 下留白。
- 卡片底色是 `CAGradientLayer` 对角渐变：浅色模式 `#F5F7FF → #E7FBF6`，深色模式 `#191C28 → #0E211E`；`traitCollectionDidChange:` 里换色，并用 `CATransaction` 关掉隐式动画。
- 左边 50×50 的图标用 ImageIO 直接读 bundle 里的 `banner@3x.png` 塞进 `layer.contents`（`kCAGravityResizeAspect`），不走 `imageNamed:inBundle:`，以免被解析到 Settings 主 bundle。
- 右边两行：22 号粗体 `Fizz`，12.5 号副标题“双指外扩，角标随图标一起散开”。标题行高 26、副标题行高 16，两者合成一块 42 高的文字块，按图标中线（`FIZZBannerPadding + 25`）居中，所以文字块顶部在卡片内 20 处，而不是和图标上沿对齐。
- 分隔线下是全局开关行：左边 17 号常规字重的“启用”（与下方列表行标题同字号），右边 `UISwitch`（`onTintColor` 是青绿 accent）。它就是总开关本身，直接读写 `com.fizz.ripple` 的 `Enabled`，不再是表里的一行，所以不会经过 specifier 的 set/get。
- 卡片里不再显示“乌龙工作室”和版本号；版本只出现在包信息里。工作室落款改到面板最底部单独一组，与工作室其他面板（例如 `SingleVPNPrefs`）一致：无标题分组 + `support_footer` footer，下面一行 `PSButtonCell`（PSCellType 13），文案是 `support_button`，点击打开 `FIZZSupportURL`（`https://havoc.app/search/82Flex`，与工作室其他插件同一个落地页）。按钮动作靠 specifier 的 `action` 属性（`fizzSupport:`），由 `PSListController` 自己派发，和 plist 里写的 `action` 完全等价。

面板要拿到表格：`FIZZFindTableView()` 从 `self.view` 往下找第一个 `UITableView`（`PSListController` 的 `view` 可能本身就是表），宽度还没算出来时先跳过；`viewDidLoad` 异步装一次，`viewDidLayoutSubviews` 每次核对，宽度变了才重设，因此不会死循环。

## 三个开关

面板只有三个开关，都写在 `com.fizz.ripple` 域里，默认都是打开（没写过值时读取回退到 `YES`）：

| 位置 | 标题 | 键 | 作用 |
| --- | --- | --- | --- |
| banner 卡片 | 启用 | `Enabled` | 全局开关。关闭后双指外扩手势直接忽略，触感、角标清空和气泡淡出也一起停掉。 |
| 唯一分组 | 触感反馈 | `Haptics` | 图标穿过原位那一刻震一下：没有角标可清时是 `Soft` 闷轻一声，有角标、气泡炸掉时是 `Rigid` 硬脆一声；关闭后只做涟漪与清空，不震动。 |
| 唯一分组 | 角标维持 | `KeepCleared` | 抑制层开关。App 打开或退到后台时会重新上报角标；打开本项时，与已清除数字相同的旧值被忽略，新数字照常显示。关闭后手势照样清空角标并让气泡淡出，但不再拦截任何上报，旧数字会随 App 回来。 |

三个开关都即时生效，不需要 respring：手势在 `Began` 时读一次全局开关，播放触感前读一次“触感反馈”；`FIZZBadgeClearAll()` 进入时读一次全局开关；抑制层在记录基线（`FIZZBadgeRecordBaseline`）和判断某次写入是否丢弃（`FIZZBadgeShouldSuppressWrite`）时各读一次“角标维持”。“触感反馈”只决定震不震动，“角标维持”不影响清空本身，也不影响气泡淡出。读取直接走 `CFPreferences`，cfprefsd 在面板保存后会把新值交给 SpringBoard，因此不需要额外注册 Darwin 通知。

App 打开会取回自己的角标数字，退到后台时又会把这个数字重新上报一次，所以清空之后它们仍会尝试把旧值写回来，这也是“角标维持”存在的理由。打开“角标维持”时，与清除前完全相同的值被丢弃，App 真有新消息、或者用户把消息读完导致的数字变化都照常生效；关闭“角标维持”时不再写新的基线，已经清掉的角标不会因此回来，但 App 下一次上报的数字会直接显示出来。重新打开时恢复记录，抑制表里的旧记录继续生效。

## 文案与本地化

面板代码里不放任何中文字面量：所有可见文字都在 `fizz/prefs/<lang>.lproj/Localizable.strings`，代码里只留英文兜底值。

已支持的 10 种语言（系统语言匹配不到时用 `en`）：`en`、`zh-Hans`、`zh-Hant`、`ja`、`ko`、`de`、`fr`、`es`、`ru`、`pt-BR`。每个语言的 `.strings` 都必须是同一组 7 个键：

| 键 | 英文（`en.lproj`） | 简体中文（`zh-Hans.lproj`） |
| --- | --- | --- |
| `enabled` | Enable | 启用 |
| `haptics` | Haptics | 触感反馈 |
| `keep_cleared` | Keep Cleared | 角标维持 |
| `banner_subtitle` | Spread two fingers to send the badges out with the icons | 双指外扩，角标随图标一起散开 |
| `badges_footer` | Apps republish their badges … the old number may come back. | App 打开或退到后台时仍会重新上报角标。打开“角标维持”后，与已清除数字相同的旧值会被忽略，新数字照常显示；关闭后旧数字可能再次出现。 |
| `support_footer` | Please support our paid works, thank you! | 请支持我们的其他付费作品，谢谢！ |
| `support_button` | Made with ♥ by OwnGoal Studio | 「乌龙工作室」倾情献制 |

- 查找走 `FIZZLocalizedString(key, fallback)`：对 `[NSBundle bundleForClass:FIZZPrefsRootListController]` 调 `localizedStringForKey:value:table:@"Localizable"`。不能用 `NSLocalizedString`，它查的是 Settings 主 bundle，拿不到面板自己的资源。
- `Info.plist` 的 `CFBundleDevelopmentRegion` 是 `en`；新增语言只要新建 `<lang>.lproj/Localizable.strings`，`apelin/build.sh` 会把所有 `*.lproj` 拷进 bundle，不需要登记。
- 各语言里 footer 都用本地化的引号包住“角标维持”那一行的名字（中文全角“”，日文「」，德/法/俄/西用 « » 或 „ “，英/韩/葡用 “”/‘’ 按当地习惯），因为同一个分组里有两个开关，不能再说“本项”。
- 各语言的“角标”用词跟随 Apple 本地化：`badge` → 日 `バッジ`、韩 `배지`、德 `Badge`、法 `pastille`、西 `distintivo`、俄 `значок`、葡 `selo`。
- 唯一分组没有标题（`groupSpecifierWithName:@""`），footer 用 `badges_footer`。
- 产品名 `Fizz`（banner 标题、面板标题、设置入口、包名）不翻译；设置入口名写在 `fizz/prefs/Fizz.plist` 的 `label` 里。
- 原“手势”分组的标题和 footer（“双指外扩清除所有角标。”）已删除，那句话改由 banner 副标题承担。
- 开关“角标维持”只改显示名，键仍是 `KeepCleared`，已保存的设置不受影响。

## 实现要点

- 面板是 `PSListController` 的子类，specifier 全部在代码里构造，没有 `Root.plist`：一个无标题的 `groupSpecifierWithName:@""` 分组（带 `footerText`）加两个 `PSSwitchCell`（PSCellType 6），末尾再一组工作室落款（无标题分组 + `PSButtonCell`，PSCellType 13，带 `action`）；总开关是 banner 卡片里的真实 `UISwitch`，不在 specifier 里。
- specifier 的 target 是控制器自身，set/get 走 `-setPreferenceValue:specifier:` 与 `-readPreferenceValue:`；写值用 `CFPreferencesSetAppValue` + `CFPreferencesAppSynchronize` 落到 `com.fizz.ripple`，读值复用 `FIZZPreferencesGetBool`，域和键只定义一次。
- `Preferences.framework` 没有公开头文件，`PSListController`、`PSSpecifier` 的方法和 `PSSwitchCell` 常量都在这个 `.m` 里自行声明。关键是 `PSListController` 的 `_specifiers` ivar：表格渲染的是这个数组，子类必须把行写进它，而不是自己另开一个 ivar。声明里带上 `_specifiers` 后，编译器引用 `_OBJC_IVAR_$_PSListController._specifiers` 这个外部符号，由 Preferences 在加载时绑定；本机其他第三方面板（`DonutPrefs`、`HelloMemoryStatusPrefs`、`hello120hz`）用的是同一套写法。
- 只写自己的 `_ownSpecifiers` 也能编译、面板标题也能出现，但表格永远零行，设置里看到的就是一个空列表。
