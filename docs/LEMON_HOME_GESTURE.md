# Lemon 主屏手势与图标涟漪

本文件记录 `lemon/LEMHomeGesture.m` 的手势接入方式、双指外扩与主屏 `SBIconScrollView` 内置 pan 的冲突处理，以及 `lemon/LEMIconRipple.m` 的涟漪参数。

## 冲突来源

主屏 `SBIconScrollView` 的 `panGestureRecognizer` 默认 `minimumNumberOfTouches=1`、`maximumNumberOfTouches=NSUIntegerMax`，双指拖动同样算一次 pan；iOS 17 主屏没有系统 pinch recognizer（`pinchGestureRecognizer=nil`），所以 Lemon 的 pinch 完全是自己装的。

两者并行时，双指外扩会把页面一起拖走；手指先后落下时还会出现“先单指拖动、再加第二指”的路径，这时 pan 已经在跑。

## 处理方式

- `LEMConfigureScrollPan` 把主屏 pan 的 `maximumNumberOfTouches` 限制为 1，双指接触不再触发 pan；configure 在 attach 时执行，并由 `SBIconScrollView` 的 `layoutSubviews` 钩子持续守住（只在值被改回时才重新设置）。
- `LEMSuppressScrollPan` 在 pinch 进入 `Began` 时把 pan 置为 `NO`，用于取消“第二指落下前已经开始”的 pan 与惯性减速；`LEMRestoreScrollPan` 在 pinch `Ended`/`Cancelled` 时恢复，另有 3 秒看门狗防止 pan 被永久禁用。
- 单指拖动不受影响：pinch 结束即恢复 pan，普通翻页仍由原 pan 处理。
- pinch recognizer 在 `Began` 时读一次全局开关；关闭开关不会移除 recognizer，下一次手势就能重新生效，不需要 respring。

## 图标涟漪

`LEMIconRippleRun` 由 pinch `Began` 且 `scale > 1.0` 时调用，内收手势不改数据也不做动画。

- 锚点是 `SBIconScrollView` 所在 window 的中心；图标按“图标中心减锚点”的向量方向外移，位移量与距离成正比，最远图标移动 26pt。
- 每个图标用两条 `CAKeyframeAnimation`（`transform.translation.x` / `.y`）走 0 → 偏移 → 0，关键时间点 0 / 0.42 / 1，`EaseInEaseOut`，总时长 0.5s；延迟按距离归一化后最多 0.1s，整体约 0.6s，视觉上从中间向外扩散。
- 动画只作用于 layer，不改 `transform` 模型值，结束后自动回到原位；`transform` 非单位矩阵（例如正在被拖动）、隐藏、透明或不在窗口内的图标会被跳过。
- 递归收集时遇到类名含 `IconView` 的视图就停下，只让最外层的图标视图动，避免图标图片视图（`SBIconImageView`）被父子各推一次。
- 只处理 `SBIconScrollView` 内的页面图标，Dock 等其他部件的图标不参与。

## 触感反馈

手势有两份 AHAP，`lemon/LEMHaptics.m` 用 Core Haptics 播放，随 dylib 一起装到 `Library/MobileSubstrate/DynamicLibraries/`，运行时用 `dladdr` 按 dylib 自身路径定位，roothide 与 rootless 都不需要硬编码前缀。读取用 `NSJSONSerialization` + `CHHapticPattern initWithDictionary:error:`，因为部署目标是 iOS 15，而 `initWithContentsOfURL:error:` 要 iOS 16。

选择规则：手势触发时若主屏还有角标可清（`LEMBadgeHasBadges()` 为 YES，且全局开关打开），播 `LEMRippleCleared.ahap`；否则播 `LEMRipple.ahap`。变体在涟漪开始前定下来，与之后 `LEMBadgeClearAll()` 的时机对齐。

两份文件的前 0.60 秒完全相同，基础节奏总长 0.62 秒（0.5 秒动画 + 最多 0.1 秒延迟 + 收尾）：

| 时间 | 事件 | 作用 |
| --- | --- | --- |
| 0.00 | 瞬态，强度 0.55、锐度 0.30 | 双指捏住的“抓”感 |
| 0.00–0.62 | 持续事件，强度曲线 0.10 → 0.85（0.06s）→ 0.50（0.30s）→ 0（0.62s） | 向外推的低频涌动，越往外越薄 |
| 0.00–0.62 | 锐度曲线 −0.20 → 0.10（0.32s）→ 0.50 | 波到达边缘时变清脆 |
| 0.14 / 0.30 / 0.47 | 瞬态，强度 0.40 / 0.30 / 0.20，锐度 0.38 / 0.47 / 0.57 | 三圈涟漪的“圈”感，越往外越轻、越尖 |
| 0.60 | 瞬态，强度 0.22、锐度 0.80 | 涟漪收束的收尾一声，只在没有角标可清的基础版里出现 |

`LEMRippleCleared.ahap` 沿用这段节奏，但去掉 0.60 的收尾一声，改在 0.64 落一下与气泡破掉同时落定的“咯噔”，总长 0.71 秒，只有这一下，后面不再补任何声音：

| 时间 | 事件 | 作用 |
| --- | --- | --- |
| 0.64 | 瞬态，强度 0.90、锐度 0.62 | “咯”：一下干净的敲击，强度和锐度都取中上，既不闷也不像针尖 |
| 0.64–0.71 | 持续事件，强度曲线 0.95 → 0.55（0.02s）→ 0（0.07s），锐度曲线 0.55 → 0.85 | 0.07 秒的身体，让这一下有分量；同时锐度上扬，收得清脆、不拖低频 |

气泡同样跑满整段涟漪：`LEMBadgePopWithRipple` 在整个 0.5 秒里把徽章涨大、最后十分之一个节拍才破掉（`opacity` 归零），最远的图标（延迟 0.1 秒）在 0.60 破完；数据清空在 0.62，这一下在 0.64 落下，与最后一批气泡破掉、清空落定几乎同时，之后没有任何低频长尾。

实现要点：

- 引擎只建一次，`playsHapticsOnly`、`isMutedForAudio`、`autoShutdownEnabled`；主屏出现时预热，空闲时由系统自动关停，`stoppedHandler` 与 `resetHandler` 维护运行状态。预热会把两份 pattern 都解析好并起引擎，第一次手势无论落在哪个变体都不用等。
- 播放前若上一段还在尾巴里，先 `stopAtTime:0` 再播新的，连续触发不叠加。
- 触感由 `LEMHapticsEnabled()` 控制，即全局开关与“触感反馈”同时打开；硬件不支持触感、AHAP 读不到或解析失败时静默不播，不影响手势与清空。
- 生产日志不记录触感，只有加载时的 `ApelinLoaded`。

## 接入与 hooks

- `SBIconScrollView` 的 `initWithFrame:` 钩子、`SBHIconManager` 的 `rootFolderControllerViewWillAppear:` 钩子负责发现并 attach scroll view；启动 2 秒后再全窗口扫一次，覆盖钩子装上之前就已经建好的主屏。
- `${PREFIX}` 里没有 Theos，钩子统一走 `lemon/LEMHook.m`：`MSHookMessageEx` 由 `dlsym` 解析，拿不到时退回 `method_setImplementation`；目标类没实现某个 selector 时，`LEMInstallHook` 沿继承链找到真正实现的类再挂。
- `layoutSubviews` 只在 `SBIconScrollView` 自己实现它时才挂，避免把 `UIScrollView` 基类的实现挂给全系统。三个钩子共 7 位，每位只装一次，缺类时每 0.1 秒重试，最多 50 次。

## 日志

生产构建只在加载时写一行 `ApelinLoaded <buildID>`，供 `confirm_loaded` 使用；手势、pan、attach 和涟漪都不写日志，因此不存在 `gesture.log`。需要重新排查时再加临时日志，不要长期保留。旧探针的 inspector 快照在 `docs/archive/2026-10-24/reverse-engineering/` 留档，不参与编译。

## 验证要点

手工观察：双指外扩时图标向外扩散、页面不位移，同时有一段跟着涟漪走的触感；有角标可清时，角标会一路淡到整段涟漪结束，最后一批淡完的同时补一下轻微的“咯噔”，没有角标时只有 0.62 秒的基础节奏；内收不触发；设置里关掉“启用”后手势、触感与角标清除都不响应，关掉“触感反馈”只停震动、手势照常，重新打开立即恢复。自动化只做构建、安装和加载确认，不代用户做手势。
