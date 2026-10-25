# Fizz 徽章清除

## 逆向结论

在 iOS 17.0 真机 SpringBoard 里 dump 出的关键事实：

- 徽章视图是 `SBIconBadgeView`，继承自 `UIView`，挂在 `SBIconView` 的图标图片子视图里。
- `SBIconBadgeView` 的复用入口是 `-prepareForReuse`；配置入口是 `-configureForIcon:infoProvider:` 与 `-configureAnimatedForIcon:infoProvider:animator:`。
- 数据源在 `SBApplication`：它提供 `badgeValue` 与 `-setBadgeValue:`。`SBIcon`（`SBApplicationIcon`）上的 `badgeNumberOrString` 只是转发值，真正可写的是 application 的 `badgeValue`。
- `SBIcon` 另有 `-setBadge:` 与 `-noteBadgeDidChange`，负责让图标视图刷新。
- 全量 dump 里没有“清除全部徽章”的一次性方法，所以只能逐图标清理。

## 为什么清完又会回来

只清 SpringBoard 进程内的对象不持久。用户离开 App、回到主屏后，App 进程会通过 XPC（BoardServices）把自己记录的角标数重新推给 SpringBoard；这条推送走的是 `-[SBApplication setBadgeValue:]`，时间点紧跟在主屏重新出现之后，所以清完再开一次 App 就会看到旧数字回来。SpringBoard 重启后并不总是重放旧值，但某条还原路径仍可能带回旧数字。

## 实现

`fizz/LEMBadgeClearer.m` 分四层：

1. 数据层：从 `SBIconController.sharedInstance` 取到 `iconManager.iconModel.leafIcons`，对每个 `badgeNumberOrString` 非空的图标先 `[application setBadgeValue:nil]`，再 `[icon setBadge:nil]`、`[icon noteBadgeDidChange]`。只清 icon 不清 application 不持久，徽章会立刻回来。
2. 持久层：清一个图标前，把它的 `bundleIdentifier` 和当时的值记进 `badge-suppression.plist`。之后 `-setBadgeValue:`、`-setBadge:`、`-remoteBadgeValueDidChange` 上收到的写入如果与记录完全相同，就直接丢弃；值不同则视为真实变化，放行并删除记录。App 重推旧值因此被吞掉，而新消息、已读归零都照常生效。这一层由设置里的“角标维持”开关控制（键 `KeepCleared`，默认打开）：关闭时手势仍然清空并按节拍让徽章淡出，但不再记录基线，也不再拦截任何写入。
3. 视图层：徽章边放大边淡出，跟随涟漪节拍。`LEMIconRippleRun` 每动画一个图标就调用 `LEMBadgePopWithRipple(icon, duration, delay)`，延迟与图标相同（最多 0.1 秒），时长取图标的一半（`LEMBadgePopBeatShare`，0.25 秒）。每个徽章只有两条 `CABasicAnimation`：`transform.scale` 从当前值缓出放大到 1.45 倍，`opacity` 从当前值线性降到 0，`fillMode` 为 forwards、不自动移除。没有中途顿点，也没有爆裂圆环。连做两次手势时同一枚徽章会再淡一次：缩放与不透明度都从 `presentationLayer` 读回当前值当作新起点，所以气泡不会闪回全尺寸。最远的图标在 0.35 秒就淡完，图标此时还在回位，那一刻的轻点与它对齐，清空仍在 0.62。
4. 复用层：hook `-prepareForReuse`、`-configureForIcon:infoProvider:`、`-configureAnimatedForIcon:infoProvider:animator:`，先清掉气泡动画（`com.lemon.badge.pop` 与 `com.lemon.badge.pop.scale`）、恢复 `hidden = NO`、`alpha = 1.0`，再调用原实现。被复用的徽章视图不会带着上一轮的隐藏状态。

数据清除必须晚于气泡消失：`setBadgeValue:nil` 会立刻让 SpringBoard 拆掉或重配徽章视图，同一个 runloop 里清数据等于动画根本看不到。所以 `LEMBadgeClearAll()` 只在涟漪整波结束后才跑（`settle = 0.5 + 0.1`，再留 0.02 秒余量），此时它做两件事：清数据、移除已淡掉视图上的动画并把仍然活着的淡掉视图 `hidden = YES`（防止数据没清掉时徽章回弹）。

## 状态文件

抑制表写在 `LEMState` 的目录下：优先 `<jbroot>/var/mobile/Library/Fizz/badge-suppression.plist`，其次 `/var/mobile/Library/Fizz/`，最后是 `NSTemporaryDirectory()/Fizz/`。目录由 SpringBoard 在第一次写入时创建，文件写成 `NSFileProtectionNone`，保证下次开机首次解锁前也能读到。旧版本放在 `<jbroot>/var/log/fizz/badge-suppression.plist` 或 `/var/jb/var/log/fizz/` 的表会在第一次读取时接管，不需要 postinst。重装或升级 Fizz 不会清掉这些文件。

## hooks

- 徽章 hook 在构造期同步安装（不等主队列），因为 SpringBoard 在主队列第一次跑块之前就已经建好图标模型并还原徽章；晚装会漏掉启动期的写入。
- 共 6 个 hook（63 位）：三个徽章视图复用入口、`SBApplication` 的 `-setBadgeValue:` 与 `-remoteBadgeValueDidChange`、`SBIcon` 的 `-setBadge:`。每个 hook 只装一次，缺类时每 0.1 秒重试，最多 50 次；`LEMBadgeClearAll()` 也会补一次安装。
- 写入拦截的判定在模块内部完成，不使用 Objective-C 异常；所有类和方法都先做 `respondsToSelector:` 检查。
- `-noteBadgeDidChange` 只用于观察，不改变行为，生产构建不再 hook 它。

## 触发

松开双指、且松开时的指距已过阈值时，`LEMRunSpread` 先跑图标涟漪（徽章随之同拍淡出），等整波结束 `settle` 秒后再调用 `LEMBadgeClearAll()` 清数据。内收手势、按住不放、以及没到阈值就松手，都不做事。

## 已验证与未覆盖

- 数据确实被清掉，不只是视觉隐藏。
- 清完再开 App：旧值被写入拦截丢弃，徽章不再回来。
- SpringBoard 重启：实测旧值不一定重放；若某条还原路径绕过了这三个写入入口，理论上可能重新显示。当前故意不加读取侧拦截，等真出现再补。
- 抑制表只记录有 `bundleIdentifier` 的图标；文件夹图标聚合的徽章不计入抑制表。
