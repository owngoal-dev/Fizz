# Lemon 主屏手势与图标涟漪

本文件记录 `lemon/LEMHomeGesture.m` 的手势接入方式、双指外扩与主屏 `SBIconScrollView` 内置 pan 的冲突处理，以及 `lemon/LEMIconRipple.m` 的涟漪参数。

## 冲突来源

主屏 `SBIconScrollView` 的 `panGestureRecognizer` 默认 `minimumNumberOfTouches=1`、`maximumNumberOfTouches=NSUIntegerMax`，双指拖动同样算一次 pan；iOS 17 主屏没有系统 pinch recognizer（`pinchGestureRecognizer=nil`），所以 Lemon 的 pinch 完全是自己装的。

两者并行时，双指外扩会把页面一起拖走；手指先后落下时还会出现“先单指拖动、再加第二指”的路径，这时 pan 已经在跑。

同样的冲突还出现在下拉搜索上：打开搜索的 pan 挂在主屏更上层的视图（`SBIconScrollView` 的祖先链上），默认最多接受两根手指。双指外扩时两指的中点只要整体往下走，它就会进入识别、把搜索界面拉下来，因此它和页面 pan 一样要一起处理，不能只盯着图标 scroll view 自己那一个 pan。

## 处理方式

- `LEMConfigureScrollPan` 从 `SBIconScrollView` 起沿祖先链（最多 12 层，覆盖到 window）遍历每一个 `UIPanGestureRecognizer`，把 `maximumNumberOfTouches` 限制为 1；主屏页面 pan 和下拉搜索的 pan 一起被限制，双指接触不再能启动它们，单指行为完全不变。`minimumNumberOfTouches > 1` 的 pan 跳过：把最大值压到最小值以下会被 UIKit 拒绝，而需要多指才能开始的 pan 本来也不是要处理的单指下拉。configure 在 attach 时执行，并由 `SBIconScrollView` 的 `layoutSubviews` 钩子持续守住（只在值被改回时才重新设置）。
- `LEMSuppressScrollPan` 在第二指落下、跟手开始时把祖先链上所有处于启用状态的 pan 置为 `NO`，用于取消“第二指落下前已经开始”的页面 pan、下拉搜索 pan 与惯性减速；`LEMRestoreScrollPan` 在手指松开、pinch `Ended`/`Cancelled`/`Failed` 时把它们逐个恢复，另有 3 秒看门狗防止 pan 被永久禁用。
- 单指拖动不受影响：手势结束即恢复 pan，普通翻页与下拉搜索仍由原来的 pan 处理。
- pinch recognizer 在跟手开始时读一次全局开关；关闭开关不会移除 recognizer，下一次手势就能重新生效，不需要 respring。

## 跟手与触发

pinch recognizer 是 `LEMSpreadPinchRecognizer`（`UIPinchGestureRecognizer` 子类）。UIKit 的 pinch 要等手指跨过它自己的阈值才进 `Began`，那之前的扩张完全拿不到，所以跟手不看它的状态，而是自己在 `touchesBegan`/`touchesMoved` 里量两指距离：

- 第二指落下时记下当时的指距作为基线，同时压制 pan 并调用 `LEMIconRippleBeginFollow` 收集本轮参与的图标。
- 之后每次移动按 `(当前指距 − 基线) / 40pt` 算进度，交给 `LEMIconRippleUpdateFollow`：进度到 1 时图标沿“图标中心减 window 中心”的方向外移到满程 26pt 的 55%，超过 1 之后继续往外，但幅度按 `0.9 × p / (p + 0.636)` 逐渐收敛，越往外每一点指距换来的位移越小，永远不会真的到达满程的 90%（`LEMRippleFollowLimitShare`）。这就是弹性限位：不是卡在某个最大值上不动，而是越推越费劲。指距缩回则目标回落，夹在 0 以上。
- 图标不直接跟着手指走：`LEMIconRippleUpdateFollow` 只设定目标占比，实际位置由一个每帧步进的弹簧追上去（`CADisplayLink` 驱动，刚度 400、阻尼 28，略微欠阻尼）。往外交和往回缩都会略微滞后一点、手指停住后还会自己再贴上去一点，偶尔有极小的过冲，而不是指哪停哪。
- 手指还按着的时候只有跟手，没有涟漪、没有触感、不清角标。
- 触发只看松手那一刻：`touchesEnded` 先用 `LEMSpreadReleaseSpan` 量出抬指位置（此时被抬起的 `UITouch` 还在 `touchesForGestureRecognizer:` 里，位置是抬起点，不是抬手前最后一次移动的位置），再交回手势状态机。
- 抬起时的指距比基线大 40pt 以上，就用 `LEMRunSpread` 起一波涟漪；`LEMIconRippleRun` 先读回图标当前所在位置作为动画起点，所以跟手到涟漪的交接没有跳变，外层再配角标清除。
- 抬起时没有到阈值，只是 `LEMIconRippleEndFollow(YES)` 用 `CASpringAnimation`（刚度 420、阻尼 21，略微欠阻尼）沿 x/y 各自把图标送回去：图标先越过原位一点点，再落回原位，收尾带一点弹性，而不是匀着停下；不起涟漪、不出触感、不清角标。
- `Cancelled`/`Failed`/`reset` 一律按“不算数”处理，无论当时指距多远。

## 图标涟漪

`LEMIconRippleRun` 由松手且指距过阈值时调用，内收手势不改数据也不做动画。

- 锚点是 `SBIconScrollView` 所在 window 的中心；图标按“图标中心减锚点”的向量方向外移，位移量与距离成正比，最远图标移动 26pt。
- 每个图标用两条 `CAKeyframeAnimation`（`transform.translation.x` / `.y`）走起点 → 偏移 → 反向越过原位 → 0，关键时间点 0 / `0.42 × (1 − 起点占比)` / 该段之后 72% / 1，`EaseInEaseOut`，总时长 0.5s；反向那段是 `LEMRippleSettleOvershoot`（满程的 6%）的拖尾回弹，图标收回来时先往内多走一点再落回原位，尾段不会突然停住。延迟按距离归一化后最多 0.1s，整体约 0.6s，视觉上从中间向外扩散。`fillMode` 设为 `kCAFillModeBackwards`，延迟期间图标停在起点，不会先弹回原位。
- 起点取图标此刻在屏幕上的位置（跟手阶段的 layer 平移，或上一波动画走到一半的位置），读完立刻把模型 `transform` 清零，因此动画本身仍然不依赖模型值；`transform` 带缩放或旋转（SpringBoard 自己在动）、隐藏、透明或不在窗口内的图标会被跳过。
- 连续多次外扩不会打断上一波：新一波从图标当前位置接着往外再弹一次，同一对动画 key 直接替换旧动画；`LEMRunSpread` 带世代号，上一波排好的 `LEMBadgeClearAll()` 发现世代号已过期就直接放弃，清空只由最后一波在自己的涟漪落定后执行。
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

手工观察：双指开始外扩、还没到阈值时图标就跟着手一起往外走，页面不位移，双指向外扩（即使两指中点往下走）也不会把搜索拉下来；手指按住不放时只有跟手，没有涟漪、没有触感、角标不清；松开时指距过阈值才扩散回位、出触感，图标收回时先越过原位一点点再落回，有角标可清时角标像气泡一样涨大后破掉，最后一批破完的同时补一下清脆的“咯噔”，没有角标时只有 0.62 秒的基础节奏；指距没到阈值就松开只原样回弹（同样带一点越过原位的回弹），触感和角标都不动；连做几次外扩时图标不会跳回原位重来，动作是从当前位置接下去的；内收不触发；单指下拉搜索、单指翻页照常；设置里关掉“启用”后手势、触感与角标清除都不响应，关掉“触感反馈”只停震动、手势照常，重新打开立即恢复。自动化只做构建、安装和加载确认，不代用户做手势。
