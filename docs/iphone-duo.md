# iPhone Duo 适配（iOS 端）

> 日期：2026-11-25。范围：`Mobile/Sources/**`（iOS 壳）。
> 环境：**Xcode 27.2 (27B52) / iOS SDK 27.2**，部署目标 iOS 26.0。
> 结论：Duo 专属 API 在 27.1 起全部到位，**铰链避让与工具栏轴向已落地**；内屏侧栏 / 主次两栏
> 经实测量宽后**否决**（内屏只有 669pt，拆栏得不偿失）。内屏姿态下的视觉效果本机无法自动验证，
> 见 §7。

## 1. 设备事实（本机实测，不是抄文档）

`xcrun simctl io <dev> enumerate` + `simctl io <dev> screenshot` + 探针（§4.4）读数：

| 形态 | 帧缓冲 | 逻辑尺寸 | 尺寸类 | 备注 |
|---|---|---|---|---|
| 外屏（合起） | 1398×2034 @3x | 466×678pt | **cmp × reg** | 可用宽度**只有 382pt** |
| 内屏（展开） | 2007×2853 @3x | 669×951pt | reg × reg（Apple 文档） | 本机无法切到该姿态 |

⚠️ **外屏右侧有 84pt 安全区保留**。这是实测出来的，不是猜的：
`UIWindowScene.keyWindow.bounds = 466×678`，而视图拿到的布局宽度是 **382pt**、
`safeAreaInsets.trailing = 84`。也就是说「外屏 = 普通 5.4" 手机，界面零改动」这句话
**只对比例成立、对可用宽度不成立**——任何按 466pt 算出来的居中都会偏 42pt。

两条硬约束（来自 Apple《Prepare your app for iPhone Duo》）：

1. **内屏不遵循 `UISupportedInterfaceOrientations`**。展开后方向不再等价于窗口形状 ⇒
   布局决策只能看尺寸类 / 容器宽度，不能看方向。
2. **双屏设备上不要引用 `UIScreen.main`**（iOS 26 起已废弃，双屏语义有歧义）。要取屏幕
   从 `window?.windowScene?.screen` 拿，缩放用 `traitCollection.displayScale`。

## 2. API 可用性（Xcode 27.2 实测）

直接 grep `iPhoneSimulator27.2.sdk` 里的 `SwiftUI.swiftinterface` / `SwiftUICore.swiftinterface`
/ `UIKit.swiftinterface`：

| 符号 | 所属 | 可用性 | 用途 |
|---|---|---|---|
| `ConcentricRectangle` | **SwiftUICore** | iOS **26.0** | 同心圆角（可作 `Shape` 用） |
| `UICornerConfiguration` | UIKit | iOS 26.0 | 同心圆角（UIKit 侧） |
| `defaultTabBarPlacement(_:)` / `AdaptableTabBarPlacement.sidebar` | SwiftUI | iOS 27.x | TabView 侧栏形态 |
| `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)` | SwiftUICore | iOS **27.1** | 铰链 / 遮挡区域 |
| `UIView.reservedRegions(kind:options:)` | UIKit | iOS 27.1 | 同上（UIKit 侧） |
| `ToolbarContent.axisBehavior(_:)` / `ToolbarItemAxisBehavior.horizontalOnly` | SwiftUI | iOS 27.1 | 工具栏竖排控制 |
| `ArrangementView` / `UIArrangementViewController` | 两者 | iOS 27.1 | 主次两栏排布 |
| `ToolbarOverflowMenu` | SwiftUI | iOS 27.1 | 溢出菜单 |
| `presentationPlacement(_:)` | SwiftUI | iOS 27.1 | sheet 靠边 |

### 被证伪的旧断言（保留，别重犯）

上一版本文档（2026-11-24，Xcode 26.0 环境）写了三条，现在两条已被推翻：

| 旧断言 | 现状 | 为什么错 |
|---|---|---|
| 「`reservedRegion(.division, includeInactive: true)`」 | ❌ 名字不对 | 真实 API 是**复数** `reservedRegions(kind:options:)`，返回 `[ReservedRegion]`；`includeInactive` 是 `QueryOptions` 的选项位，不是参数名。`ReservedRegion` 有 `frame` / `margins` / `isActive` / `kind` / `id` |
| 「SwiftUI 侧没有 `ConcentricRectangle`」 | ❌ 有，且 iOS 26.0 起 | 它定义在 **SwiftUICore**，上一版只 grep 了 `SwiftUI.swiftinterface` 所以漏了。教训：**SwiftUI 的符号有一大半住在 SwiftUICore** |
| 「本机 SDK 装不下任何 Duo 专属 API」 | ✅ 当时成立 | 26.0 SDK 确实没有 27.1 的符号；本机升级到 27.2 后全部到位 |

## 3. 本仓审计结果（Duo 反模式逐条查过）

| Apple 点名的反模式 | 本仓 | 证据 |
|---|---|---|
| 引用 `UIScreen.main` | ✅ 无 | `grep -rn "UIScreen" Mobile/Sources` 零命中 |
| 按方向布局（`UIDevice.orientation` / `interfaceOrientation`） | ✅ 无 | 同上 |
| 按 `userInterfaceIdiom` 分支 | ✅ 无 | 同上 |
| 按已知机型尺寸硬编码 | ✅ 无 | `.frame(width:)` 命中项全是图标 / 印章 / 圆钮的固有尺寸 |
| 假设左右安全区相等 | ✅ 无 | 悬浮栏走 `.padding(.horizontal, 28)` 叠在安全区之内，两侧各自累加 |
| `UIRequiresFullScreen` 锁死 | ✅ 未声明 | `Mobile/MEditorMobile/Info.plist` 无此键 |
| 自建 bar（基于 `UITabBar` / `UINavigationBar` / `UIToolbar`） | ⚠️ **曾中招，已修** | 底栏与文档动作条都是自绘，系统不会替它们竖排 ⇒ 外屏上一直挂在底部。纵向形态改用系统 tab 栏 + 导航栏 toolbar，见 §4.5 |

## 4. 已完成的适配

### 4.1 宽度封顶（`AdaptiveChrome`，上一版就有的部分）

三个上限 + `readableColumn(_:)`：正文 720pt、动作栏 620pt、列表/表单 820pt。
**只封顶、不撑开** ⇒ 402pt 的 iPhone 上取原值，compact 形态零副作用，不需要尺寸类分支。

⚠️ 顺序陷阱：需要通栏背景时 `.background(...)` 必须加在 `readableColumn` **之后**
（该修饰符末尾已经 `frame(maxWidth: .infinity)`）。

### 4.2 铰链避让（本次新增）

半折 / 帐篷姿态下铰链会把内屏切成几块。原则（Apple 的比喻是「跨书脊的照片不再是完整照片」）：

- **连续滚动的正文不位移**——位移会打断阅读，跨折痕只是看着别扭。
- **成簇的 chrome 必须避让**——底栏两条胶囊跨过折痕就成了两组控件。

实现：

- `AdaptiveChrome.freeSpans(width:dividers:)`：把铰链占用的横坐标区间切成若干连续区间，
  相交 / 相邻的 division 先合并（否则会切出宽度 0 的碎片）。
- `HingeLayout`：窗口宽度 + 铰链区间 + 安全区内缩，`chromeSpan(cap:)` 给出
  「封顶宽度 + 横移量」；无铰链时恒为 `(cap, 0)`，与改动前**逐像素等价**。
- `.chromeColumn(_:)`：只给 chrome 用的修饰符，居中到**最宽的连续区域**。
- 运行期判断：`reservedRegions` 是 iOS 27.1 起才有的，部署目标 26.0，低版本上取不到铰链、
  退化成「整幅窗口」，不崩不改版式。

⚠️ **就地测量，别在根部量**。踩过的坑：在 `RootView` 的 ZStack 上 `onGeometryChange`
拿到的是 **382pt**（安全区宽度），而底栏自己的容器也是 382pt——但两者一旦分处不同层级
（比如将来把底栏移到 `.safeAreaInset`），`spanCenter - W/2` 就会差 42pt。
现在 `ChromeColumn` 在**自己的背景里**量，宽度与铰链坐标必然同源。

### 4.3 工具栏竖排

27.1 起标准工具栏按钮在内屏会走竖排。`DocumentView` 的 `.principal` 里是**双行标题**
（文件名 + 字数），竖排会被压成两行窄字，所以用 `.axisBehavior(.horizontalOnly)` 显式要求横向。
`ToolbarItem` 是 `ToolbarContent`，`.axisBehavior` 只能挂在它上面——因此标题被抽成
`principalItem` / `principalTitle` 两个成员，按 `#available(iOS 27.1, *)` 分两条路径。

### 4.4 探针与断言（让下次改动可验证）

**布局探针**（DEBUG-only）：`-debugLayoutProbe YES` 打开，左上角显示
窗口宽度 / 安全区 / 尺寸类 / 缩放 / division 区间 / occlusion 区间 / 连续区间。
没有它，铰链相关的改动在自动截图里永远看不见。

**几何断言**：`scripts/verify_hinge_math.swift` 把 `AdaptiveChrome.swift` 编进一个 macOS
命令行程序，直接跑 19 条断言（切分、合并、封顶、横移、退化）：

```bash
swiftc -parse-as-library Mobile/Sources/Theme/AdaptiveChrome.swift scripts/verify_hinge_math.swift \
  -o /tmp/verify_hinge_math && /tmp/verify_hinge_math
```

**反向验证**（仓规 §6 要求）：把 `hingeClearance` 从 12 改成 20，4 条断言立刻变红；
改回 12 恢复全绿。不是空断言。

### 4.5 侧边纵向控件（本次新增，2026-11-27）

**结论先行**：底栏原来那一整条自绘 chrome 在外屏上是**错的**。HIG《Designing for iPhone Duo》：

> On iPhone Duo, you should position your **toolbars, tab bars and controls along the side**
> of the device so they're easier to reach. Controls share this vertical space with dynamic
> elements like live activities and the status bar.

《Preparing your app for iPhone Duo》把「为什么它没自动生效」也写清楚了——系统只会搬**它自己的**
bar，自建 bar 不在此列：

> If the system doesn't present your bars vertically, check that you're using the bar support
> that navigation containers provide… instead of creating a custom bar for your view based on
> `UIToolbar`, `UINavigationBar`, or `UITabBar`.

本仓恰恰是后者：`RootView` 用 `.toolbar(.hidden, for: .tabBar)` 藏了系统 tab 栏，`BottomBarView`
与 `DocActionBar` 全是自绘。所以外屏上它一直老实待在底部，右侧那条纵向空间只留给系统状态栏。

**判据**：Apple 给自定义视图的官方环境值（iOS 27.1+，部署目标 26.0 ⇒ 低版本恒 false）：

| 能力 | SwiftUI | UIKit |
|---|---|---|
| 系统是否把 bar 竖排 | `toolbarVerticalEdge: HorizontalEdge?` | `verticalBarEdge` trait |

封装成 `VerticalChromeProbe`（`AdaptiveChrome.swift`）：读到非 nil 就写 `\.verticalChrome = true`
进环境，子视图据此切换形态。**不用尺寸类、不用机型**——竖排与否只有这一个事实来源。

**两种形态**：

| 形态 | 系统 tab 栏 | 一级导航 | 文档动作 | 内容底部留白 |
|---|---|---|---|---|
| 横向（普通 iPhone / iPad / 内屏竖排） | 隐藏 | 自绘玻璃胶囊（底部左右两簇） | 自绘 `DocActionBar` | 84pt |
| 纵向（Duo 外屏 / 内屏横排） | **显示**（系统排在右下竖列） | 同上：系统 tab 栏 | 导航栏 `topBarTrailing`（图标+Label） | 0（`bottomBarContentInset`） |

为什么纵向时用系统 tab 栏而不是把胶囊转 90°：溢出、压缩、折叠避让、安全区、RTL 全是系统免费的，
自己转一遍等于把这些坑重写一遍，而且离 HIG「不要自建 bar」更远。

⚠️ **纵向 bar 只认图标或 `Label`**：条目若是「只有标题」或「自定义视图」（`BarAIButton` /
`BarPlusButton` 这种带 `frame` + `matchedGeometryEffect` 的自定义 label），系统**不会**把它放进
纵向栏，会静默消失。所以纵向形态下的动作钮一律用 `Button { } label: { Label(...) }`，
hero 的 matchedGeometry 动画在这一形态下不参与（可接受：那套动画是底部胶囊的语言）。

**验证**（Duo 外屏，`xcrun simctl io <dev> screenshot --display=primary`）：

- 文档页：右侧竖列自上而下＝返回 / 编辑预览切换 / AI / 新建 / ⋯，底部胶囊消失；探针读数
  `w 382 safe 0/84 · cmpxreg`，正文仍止于 382pt，未被竖列遮挡。
- 首页：右侧竖列＝文件夹 / AI / 加号，右下＝系统 tab 栏（文档 + 设置两枚），底部胶囊消失。
- iPhone 18 Pro（402pt，横向 bar）：底部两簇玻璃胶囊原样保留，导航栏**没有**多出动作钮 ⇒ 零回归。

## 5. 实测数据（无头模拟器截图 + 像素量宽）

`xcrun simctl io <dev> screenshot` 之后用 `PIL` 量「墨迹」的横坐标范围（脚本见 §8）。

| 设备 | 逻辑宽 | 场景 | 墨迹横跨 | 判定 |
|---|---|---|---|---|
| Duo 外屏 | 466（安全区 382） | 预览正文 | 22.7–442.3pt | 22.7pt 页边距，与改动前一致 ✅ |
| Duo 外屏 | 同上 | 底部动作栏 | 22.7–354.3pt | **改动前后逐像素一致** ✅ |
| iPhone 18 Pro | 402 | 预览正文 | 22.7–374.7pt | 22pt 页边距，无回归 ✅ |
| iPhone 18 Pro | 402 | 底部动作栏 | 27.3–374.3pt | 无回归 ✅ |
| iPad Pro 13" | 1032 | 预览正文 | 156.5–846pt（列 156–876） | 720pt 封顶 + 精确居中 ✅ |
| iPad Pro 13" | 1032 | 底部动作栏 | 238.5–795.5pt（557 宽） | 中心 517 ≈ 1032/2 ✅ |

## 6. 决策：四件「不做」的事，各有数字依据

| 事项 | 决定 | 依据 |
|---|---|---|
| 内屏侧栏（`defaultTabBarPlacement(.sidebar)`） | ❌ 不做 | 内屏只有 **669pt**。侧栏按 Apple 常见 280–320pt 算，留给正文 350–390pt —— 比 402pt 的普通 iPhone 还窄。本仓的 tab 栏是 `.toolbar(.hidden)` + 自绘底栏，改侧栏等于重做一级导航，收益为负 |
| 主次两栏（`ArrangementView`，文档 + AI） | ❌ 不做 | 同一笔账：669pt 对半分 ≈ 330pt/栏，Markdown 正文一栏 330pt 会让代码块与表格大面积折行 |
| 同心圆角（`ConcentricRectangle`） | ❌ 暂不用 | API 26.0 起就有（见 §2），但本仓没有「嵌在带圆角容器里、且贴着容器边」的卡片——卡片都浮在纸底上，硬套同心圆角只会算出 0 或负半径。等真出现贴边嵌套（如 sheet 内贴边工具栏）再上 |
| 多场景 / `NavigationSplitView` | ❌ 不做 | `DocumentStore` / `ChatModel` 是 App 级 `@State`，两个窗口会镜像同一篇文档；split view 需要把导航从 `showDocument` 布尔改成 selection 驱动。两者都是独立重构 |

## 7. 未验证的部分（如实说明）

**本机切不到「展开 / 半折 / 帐篷」姿态**，因此：

- 内屏（669pt，reg × reg）的版式**没有截图证据**，只有几何推导。
- 铰链避让的**视觉效果没被验证过**——所有可测设备上 `reservedRegions(.division)` 都返回空数组
  （探针读数 `div 0`），走的是「无铰链」分支。该分支与改动前逐像素一致（§5 第 2 行），
  所以**不会坏，但也还没被证明对**。合并的是数学（19 条断言）与集成（编译 + 零回归），
  不是观感。

为什么不能自动切姿态：Xcode 27 已用 **DeviceHub** 取代 `Simulator.app`（本机
`/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app` 不存在，
`Contents/Applications/DeviceHub.app` 里也没有 fold / posture 菜单），
`simctl` 只有 `io screenConfig power|geometry`，没有姿态开关；Duo 模拟器的内屏
（display class 0，2007×2853）在合起状态下是休眠的，关掉外屏、重启 App 都不会迁过去。

**人工验证步骤**（有真机或能开合的模拟器窗口时）：

1. 装 Debug 包，`-debugLayoutProbe YES` 启动。
2. 依次摆成 合起 / 展开 / 半折 / 帐篷 / 横竖，每摆一次截图，看探针三行读数：
   `div` 是否出现、区间位置、`span` 是否切成了两块。
3. 半折时确认底栏**整簇落在较大的一块**里，没有骑在折痕上；正文**不动**是预期行为。
4. 展开时确认底栏仍在 620pt 封顶内居中、标题没被压成两行窄字。

## 8. 复现命令

```bash
# 构建（模拟器）
xcodebuild -project Mobile/MEditorMobile.xcodeproj -scheme MEditorMobile \
  -configuration Debug -destination 'id=<sim-id>' -derivedDataPath /tmp/dd-mobile build \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-disable-sandbox'

# 安装 + 带探针启动（-debugSeedDocument preview|edit 是 DEBUG-only 钩子）
xcrun simctl install <sim-id> /tmp/dd-mobile/Build/Products/Debug-iphonesimulator/MEditorMobile.app
xcrun simctl launch <sim-id> com.meditor.mobile -debugSeedDocument preview -debugLayoutProbe YES

# 截图：Duo 有两块屏，必须指定 --display
xcrun simctl io <sim-id> enumerate          # 列出屏与 UUID
xcrun simctl io <sim-id> screenshot --display=primary /tmp/shot.png

# 造一台宽画布设备来验证 regular 布局（内屏姿态切不过去时的替代）
xcrun simctl create "iPad-verify" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB \
  com.apple.CoreSimulator.SimRuntime.iOS-27-2

# 量「墨迹」横坐标（判封顶与居中）
python3 - <<'PY'
from PIL import Image
from collections import Counter
im = Image.open('/tmp/shot.png').convert('RGB'); px = im.load(); w, h = im.size
y0, y1 = int(h*0.28), int(h*0.62)                     # 避开导航栏与底栏
c = Counter(px[x, y] for y in range(y0, y1, 3) for x in range(0, w, 3))
bg = c.most_common(1)[0][0]
cols = [x for x in range(w)
        if sum(1 for y in range(y0, y1, 2)
               if sum(abs(a-b) for a, b in zip(px[x, y], bg)) > 24) >= 2]
print(min(cols)/3, max(cols)/3)                        # 缩放按设备取（Duo/iPad 见 §1）
PY
```

## 9. 已知短板

- `SettingsView` 的五个表单只做了宽度封顶，没做内屏两列（设置项只有十几行，收益低）。
- 底部两条胶囊在宽画布上仍分列左右（557pt/620pt 封顶后靠 `Spacer` 撑开），没有「收成一簇」。
  真要收，得先把一级导航换成侧栏——见 §6。
- DEBUG 钩子 `-debugSeedDocument` 在**首次**冷启动时偶尔不自动进入文档页（第二次正常），
  原因未查（怀疑 `store.hasDocument` 与 `onAppear` 的时序），只影响走查、不影响产品路径。
