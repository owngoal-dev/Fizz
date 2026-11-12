# Fizz 主屏手势与图标涟漪

本文件记录 `fizz/FIZZHomeGesture.m` 的手势接入方式、双指外扩与主屏 `SBIconScrollView` 内置 pan 的冲突处理，以及 `fizz/FIZZIconRipple.m` 的涟漪参数。

## 冲突来源

主屏 `SBIconScrollView` 的 `panGestureRecognizer` 默认 `minimumNumberOfTouches=1`、`maximumNumberOfTouches=NSUIntegerMax`，双指拖动同样算一次 pan；iOS 17 主屏没有系统 pinch recognizer（`pinchGestureRecognizer=nil`），所以 Fizz 的 pinch 完全是自己装的。

两者并行时，双指外扩会把页面一起拖走；手指先后落下时还会出现“先单指拖动、再加第二指”的路径，这时 pan 已经在跑。

同样的冲突还出现在下拉搜索上：打开搜索的 pan 挂在主屏更上层的视图（`SBIconScrollView` 的祖先链上），默认最多接受两根手指。双指外扩时两指的中点只要整体往下走，它就会进入识别、把搜索界面拉下来，因此它和页面 pan 一样要一起处理，不能只盯着图标 scroll view 自己那一个 pan。

## 处理方式

- `FIZZConfigureScrollPan` 从 `SBIconScrollView` 起沿祖先链（最多 12 层，覆盖到 window）遍历每一个 `UIPanGestureRecognizer`，把 `maximumNumberOfTouches` 限制为 1；主屏页面 pan 和下拉搜索的 pan 一起被限制，双指接触不再能启动它们，单指行为完全不变。`minimumNumberOfTouches > 1` 的 pan 跳过：把最大值压到最小值以下会被 UIKit 拒绝，而需要多指才能开始的 pan 本来也不是要处理的单指下拉。configure 在 attach 时执行，并由 `SBIconScrollView` 的 `layoutSubviews` 钩子持续守住（只在值被改回时才重新设置）。
- `FIZZSuppressScrollPan` 在第二指落下、跟手开始时把祖先链上所有处于启用状态的 pan 置为 `NO`，用于取消“第二指落下前已经开始”的页面 pan、下拉搜索 pan 与惯性减速；`FIZZRestoreScrollPan` 在手指松开、pinch `Ended`/`Cancelled`/`Failed` 时把它们逐个恢复，另有 3 秒看门狗防止 pan 被永久禁用。
- 单指拖动不受影响：手势结束即恢复 pan，普通翻页与下拉搜索仍由原来的 pan 处理。
- pinch recognizer 在跟手开始时读一次全局开关；关闭开关不会移除 recognizer，下一次手势就能重新生效，不需要 respring。
- pinch recognizer 设了 `cancelsTouchesInView = YES`：双指外扩一旦被识别，落在图标上的触摸就被取消，不会在某个手指松开（正好停在某个 App 上）时被图标当成 tap 而打开应用。

## 编辑态

主屏进入编辑（图标抖动、角上出现删除按钮）时双指外扩一律不响应：没有跟手、没有涟漪、不动角标、不出触感，也不压制 `SBIconScrollView` 的 pan——编辑态下第二根手指属于拖动图标这件事，Fizz 不去抢。

- 状态判定在 `FIZZHomeScreenIsEditing`：先问 `SBIconController` 的 `iconManager`（`SBHIconManager -isEditing`），再问 `SBIconController -isEditing`，最后才退到视图层——从 `SBIconScrollView` 往下最多 4 层找类名前缀为 `SBIconListView` 的视图并读它自己的 `isEditing`。只要图标侧有一个类真的实现了 `isEditing`，它的返回值就是结论，某个类没实现（不同系统版本不一样）才继续往下问，全部没实现才去翻视图。
- 拦截点三处，都读实时状态而不是装 hook 时缓存：`FIZZSpreadTrackTouches` 进入时直接返回，所以编辑态下根本不会开始跟手；`FIZZSpreadFinish` 在松手时再查一次，防止“开始跟手之后才进入编辑态”这一路径把涟漪放出来；`gestureRecognizerShouldBegin:` 与 `handlePinch:` 也查，让 UIKit 自己的 pinch 状态机同步放弃。
- recognizer 不会因为编辑态被移除，`isEditing` 每根手指落下时现读一次，退出编辑后下一次手势立刻恢复，不需要 respring。
- 编辑态期间单指/双指拖动图标、翻页、下拉搜索都保持系统原样。

## 跟手与触发

pinch recognizer 是 `FIZZSpreadPinchRecognizer`（`UIPinchGestureRecognizer` 子类）。UIKit 的 pinch 要等手指跨过它自己的阈值才进 `Began`，那之前的扩张完全拿不到，所以跟手不看它的状态，而是自己在 `touchesBegan`/`touchesMoved` 里量两指距离：

- 第二指落下时记下当时的指距作为基线，同时压制 pan 并调用 `FIZZIconRippleBeginFollow` 收集本轮参与的图标。
- 之后每次移动按 `(当前指距 − 基线) / 40pt` 算进度，交给 `FIZZIconRippleUpdateFollow`：进度到 1 时图标沿“图标中心减 window 中心”的方向外移到满程 26pt 的 55%，超过 1 之后继续往外，但幅度按 `0.9 × p / (p + 0.636)` 逐渐收敛，越往外每一点指距换来的位移越小，永远不会真的到达满程的 90%（`FIZZRippleFollowLimitShare`）。这就是弹性限位：不是卡在某个最大值上不动，而是越推越费劲。指距缩回则目标回落，夹在 0 以上。
- 图标不直接跟着手指走：`FIZZIconRippleUpdateFollow` 只设定目标占比，实际位置由一个每帧步进的弹簧追上去（`CADisplayLink` 驱动，刚度 400、阻尼 28，略微欠阻尼）。往外交和往回缩都会略微滞后一点、手指停住后还会自己再贴上去一点，偶尔有极小的过冲，而不是指哪停哪。
- 手指还按着的时候只有跟手，没有涟漪、没有触感、不清角标。
- 触发只看松手那一刻：`touchesEnded` 先用 `FIZZSpreadReleaseSpan` 量出抬指位置（此时被抬起的 `UITouch` 还在 `touchesForGestureRecognizer:` 里，位置是抬起点，不是抬手前最后一次移动的位置），再交回手势状态机。
- 抬起时的指距比基线大 40pt 以上，就用 `FIZZRunSpread` 起一波涟漪；`FIZZIconRippleRun` 先读回图标当前所在位置作为动画起点，所以跟手到涟漪的交接没有跳变，外层再配角标清除。
- 抬起时没有到阈值，只是 `FIZZIconRippleEndFollow(YES)` 用 `CASpringAnimation`（刚度 420、阻尼 21，略微欠阻尼）沿 x/y 各自把图标送回去：图标先越过原位一点点，再落回原位，收尾带一点弹性，而不是匀着停下；不起涟漪、不出触感、不清角标。
- `Cancelled`/`Failed`/`reset` 一律按“不算数”处理，无论当时指距多远。

## 图标涟漪

`FIZZIconRippleRun` 由松手且指距过阈值时调用，内收手势不改数据也不做动画。

- 锚点是 `SBIconScrollView` 所在 window 的中心；图标按“图标中心减锚点”的向量方向外移，位移量与距离成正比，最远图标移动 26pt。
- 松手后不是一个固定的 0.5s 关键帧曲线，而是**按弹簧把整段运动积分出来**再交给 Core Animation，而且只有**回程**一条弹簧（`FIZZRippleReturnStiffness = 420`、`FIZZRippleReturnDamping = 21`）：从松手位置拉回 0，不把没扩到满程的图标再补送出去。松手时带的外扩速度会让它靠惯性多走一点点，但径向位置被 `|offset|` 卡住，永远不会越过满程 26pt。模拟步长 1/240、按 1/60 采样，最多 1.4s，位移小于 0.15pt 且速度小于 2pt/s 时判定睡去并结束。
- **速度是继承的**：初速度取跟手弹簧在松手瞬间的 `gFollowVelocity`（share/s）乘该图标自己的 offset，即图标真实的速度向量；被封顶到 400pt/s，防止掉帧产生离谱初速度。位置同样取松手瞬间的 presentation 平移量，读完把模型 `transform` 清零，动画与模型值无关。
- 延迟按距离归一化后最多 0.1s，但会乘 `1 − 已带出比例`（`followShare / 0.9` 夹在 0…1）：手指已经把图标带出去时不再冻结等拍子，两段式的停顿感主要来自这里。
- `touchdown`（触感时刻）与 `settle`（清空时刻）不再由解析公式算，而是模拟过程中记录：回程投影由正变负的那一刻是该图标的 touchdown，模拟睡去的那一刻是它的 settle，取所有图标里的最大值。若这一波没有图标位移、只弹了角标，settle 用“角标时长 0.25 + 最大延迟 0.1”。
- `transform` 带缩放或旋转（SpringBoard 自己在动）、隐藏、透明或不在窗口内的图标会被跳过；`fillMode = kCAFillModeBackwards` 在延迟期间保持起点值。
- 连续多次外扩不会打断上一波：新一波从图标当前位置接着往外再弹一次，同一对动画 key 直接替换旧动画；`FIZZRunSpread` 带世代号，上一波排好的 `FIZZBadgeClearAll()` 发现世代号已过期就直接放弃，清空只由最后一波在自己的涟漪落定后执行。
- **可打断**：跟手开始时会先读每个图标的 presentation 平移量，把上一波还挂着的四条动画（`transform.translation.x/.y`、两条回程弹簧）全部移除，再把该位置写成模型 `transform` 并记进 `gFollowBases`；本阶段的位移是 `base + offset × share`，从 0 开始，所以第二次手势接在第一次的空中位置继续，不会等旧动画放完，也不会跳回原位。平均已带出比例记在 `gFollowCarried`，松手时并入延迟缩短。
- 松手这一遍只走**一次**树：从 window 出发，同一个递归里同时收“页面图标”（`SBIconView` 且 `isDescendantOfView:` 落在 `SBIconScrollView` 里）和“屏幕上的角标”（`SBIconBadgeView`）。遇到角标就不再往下走；遇到图标视图仍然继续下潜，因为角标挂在图标里的图片视图上。深度上限 12（比只收图标那遍深，必须穿过根文件夹、页面滚动视图、图标列表、图标、图片视图才到角标）。
- 跟手开始时那一遍仍然只在 `SBIconScrollView` 里收图标，深度上限 8，遇到图标视图就停，只让最外层的图标视图动，避免图标图片视图（`SBIconImageView`）被父子各推一次。
- 位移只作用于页面图标；Dock 等部件的图标不参与位移，但它们的角标会被松手那一遍收到一起做动画。整段逻辑里没有对 Dock 类名的判断：Dock 图标不动的依据是“不是页面滚动视图的后代”。

## 触感反馈

只在图标落回原位的那一刻震一下，用系统自带的 `UIImpactFeedbackGenerator`；有没有角标决定这一下的手感，手势本身不震。

- 触发条件：手势真的触发了涟漪（`FIZZIconRippleRun` 返回的 `touchdown` 非 0），并且全局开关与“触感反馈”都打开。没到阈值就松开只回弹，不震。
- 时机：`FIZZIconRippleRun` 现在返回 `FIZZRippleTiming`，含 `settle` 与 `touchdown` 两个时刻。触感排的是 `touchdown`——每个图标在回程里先穿过自己的原位、再冲出一小段过冲（`FIZZRippleSettleOvershoot = 0.06`）才停稳，穿过原位那一刻才是“落回”，`settle` 是过冲尾巴跑完的时刻，比它晚一百多毫秒，按 `settle` 排就会明显慢半拍。
- `touchdown` 的算法：单图标的外扩段在小数上占 `FIZZRippleOutKeyTime × (1 − startShare)`，过冲点在 `outTime + (1 − outTime) × FIZZRippleSettleKeyShare`；这一段的值从整段位移走到 −6%，穿过 0 时走完了 1/1.06，用 `FIZZRippleEaseInEaseOutInverse` 对 `kCAMediaTimingFunctionEaseInEaseOut`（cubic-bezier(0.42, 0, 0.58, 1)）二分反解出对应的段内时间比例（约 0.833），再乘回动画时长加上该图标的延迟，取所有图标里最晚的一个。手指送出去的距离（`startShare`）越大，图标归位越早，这个值也跟着变。
- 两种手感：没有角标可清时 `FIZZHapticSettleKindEmpty`，用 `UIImpactFeedbackStyleSoft`，一声闷而轻的轻响；有角标、气泡在去路上炸掉时 `FIZZHapticSettleKindCleared`，用 `UIImpactFeedbackStyleRigid`，同样一下但硬而脆。两者都是单次 `impactOccurred`，没有自定义节奏。
- 轻重在松手那一刻决定：`clearingBadges = FIZZFeatureEnabled() && FIZZBadgeHasBadges()`，随后排队的那一下带的是这个值。
- 连打不叠加：排队前记下本轮 `gSpreadGeneration`，到点时若已有新的一轮接管就放弃，由新一轮自己排它那一下，因此不会连响、也不会提前响。
- `fizz/FIZZHaptics.m` 按 kind 各留一个生成器，第一次用到哪个就建哪个，之后一直活着。
- 预热只在手势起点做一次：第二根手指落下、`FIZZSpreadTrackTouches` 判定跟手开始时调 `FIZZHapticsPrewarm()`，把两个生成器一起 `prepare`（不知道松手时会不会清角标，所以两个都要热）。播完不再重新 `prepare`，主屏出现时也不预热——那些时刻离真正震动太远，引擎早凉了，只是白叫一次。
- 触感由 `FIZZHapticsEnabled()` 控制，即全局开关与“触感反馈”同时打开；关闭时 `FIZZHapticsPlaySettle()` 直接返回，不建生成器也不准备。
- 生产日志不记录触感，只有加载时的 `ApelinLoaded`。

## 气泡消失

徽章跟着涟漪的节拍一起走，但它是**按角标视图收集**的，不跟着某个图标走：松手那一遍树里见到的每个可见角标都会弹，包括 Dock 里那些图标本身不位移的角标。`FIZZBadgePopBadge` 拿到的是按同一条规则算出的延迟——`0.1s × (角标中心到 window 中心的距离 / 最远参与图标的距离)`，这和图标延迟 `0.1 × 偏移长度 / 26` 等价，所以页面上的角标与自己的图标完全同步，Dock 的角标按自己的距离插进同一节拍。时长只取图标的一半（`FIZZBadgePopBeatShare = 0.5`，0.25 秒）。每个徽章只做两件事——`transform.scale` 从当前值缓出放大到 1.45 倍，`opacity` 从当前值线性降到 0。没有中途顿点，没有爆裂圆环；最远的角标（延迟 0.1 秒）在 0.35 秒就淡完，比图标归位早，触感那一下落在图标穿过原位的 0.44 秒，数据清空在落定后的 0.62；若这一波没有任何图标位移（例如图标都在 Dock），落定时间改用 0.35 秒，清空仍排在角标淡完之后。被清过又重新弹出时从当时的缩放和不透明度接着做，不会跳回原样。

## 接入与 hooks

- `SBIconScrollView` 的 `initWithFrame:` 钩子、`SBHIconManager` 的 `rootFolderControllerViewWillAppear:` 钩子负责发现并 attach scroll view；启动 2 秒后再全窗口扫一次，覆盖钩子装上之前就已经建好的主屏。
- `${PREFIX}` 里没有 Theos，钩子统一走 `fizz/FIZZHook.m`：`MSHookMessageEx` 由 `dlsym` 解析，拿不到时退回 `method_setImplementation`；目标类没实现某个 selector 时，`FIZZInstallHook` 沿继承链找到真正实现的类再挂。
- `layoutSubviews` 只在 `SBIconScrollView` 自己实现它时才挂，避免把 `UIScrollView` 基类的实现挂给全系统。三个钩子共 7 位，每位只装一次，缺类时每 0.1 秒重试，最多 50 次。

## 日志

生产构建只在加载时写一行 `ApelinLoaded <buildID>`，供 `confirm_loaded` 使用；手势、pan、attach 和涟漪都不写日志，因此不存在 `gesture.log`。需要重新排查时再加临时日志，不要长期保留。旧探针的 inspector 快照在 `docs/archive/2026-10-24/reverse-engineering/` 留档，不参与编译。

## 验证要点

手工观察：双指开始外扩、还没到阈值时图标就跟着手一起往外走，页面不位移，双指向外扩（即使两指中点往下走）也不会把搜索拉下来；手指按住不放时只有跟手，没有涟漪、没有触感、角标不清；松开时指距过阈值才扩散回位，图标收回时先越过原位一点点再落回，穿过原位的那一刻手机震一下；没有角标时是闷轻的一声（`Soft`），有角标、气泡炸掉时是硬脆的一声（`Rigid`），两者都在图标穿过原位的同一瞬间，气泡本身在 0.35 秒就淡完、不跟着震；指距没到阈值就松开只原样回弹（同样带一点越过原位的回弹），触感和角标都不动；连做几次外扩时图标不会跳回原位重来，动作是从当前位置接下去的；内收不触发；单指下拉搜索、单指翻页照常；设置里关掉“启用”后手势、触感与角标清除都不响应，关掉“触感反馈”只停最后那一下、手势照常，重新打开立即恢复。自动化只做构建、安装和加载确认，不代用户做手势。
