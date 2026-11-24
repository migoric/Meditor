# iPhone Duo 适配（iOS 端）

> 日期：2026-11-24。范围：`Mobile/Sources/**`（iOS 壳）。
> 结论：**本机 SDK 装不下任何 Duo 专属 API**，所以这次只做与 SDK 无关的布局适配 +
> 把 27 / 27.1 的迁移清单写死在这里。想拿到官方描述的「完整内屏体验」（竖排工具栏、
> 侧栏、铰链避让）必须升级到 **Xcode 27.1**。

## 1. 设备事实（Apple 2026-09 发布）

| 形态 | 尺寸 | 尺寸类 | 备注 |
|---|---|---|---|
| 外屏（合起） | 5.4" | 竖 compact × regular / 横 compact × compact | 与普通 iPhone 一致，界面零改动 |
| 内屏（展开） | 7.6" | **regular × regular** | 面积比 18 Pro Max 大 50% |
| 半折（书本 / 帐篷） | — | — | 铰链把内屏分成多个可用区域 |

两条硬约束（来自 Apple《Prepare your app for iPhone Duo》）：

1. **内屏不遵循 `UISupportedInterfaceOrientations`**。展开后方向不再等价于窗口形状 ⇒
   布局决策只能看尺寸类 / 容器宽度，不能看方向。
2. **双屏设备上不要引用 `UIScreen.main`**（iOS 26 起已废弃，双屏语义有歧义）。要取屏幕
   从 `window?.windowScene?.screen` 拿，缩放用 `traitCollection.displayScale`。

## 2. API 可用性（本机实测，不是查文档推的）

本机是 **Xcode 26.0 / iPhoneSimulator 26.0 SDK**。直接 grep SDK 的
`SwiftUI.swiftinterface` 与 `UIKit.swiftinterface`：

| 符号 | 所属 | SDK 26.0 有吗 | 用途 |
|---|---|---|---|
| `onGeometryChange` | SwiftUI | 有（4 处） | 尺寸变化的现代获取方式 |
| `containerRelativeFrame` | SwiftUI | 有（3 处） | 相对容器取宽 |
| `sidebarAdaptable` | SwiftUI | 有（1 处） | TabView 侧栏形态 |
| `UICornerConfiguration` | UIKit | 有（13 处） | 同心圆角 |
| `defaultTabBarPlacement(.sidebar)` | SwiftUI | **无** | 内屏侧栏 |
| `GeometryProxy.reservedRegion` / `UIView.reservedRegion` | 两者 | **无** | 铰链 / 摄像头避让（27.1） |
| `ArrangementView` / `UIArrangementViewController` | 两者 | **无** | 主次两栏排布（27.1） |
| `axisBehavior(.verticalPreferred)` / `.horizontalOnly` | SwiftUI | **无** | 工具栏竖排（27.1） |
| `ToolbarOverflowMenu` / `UINavigationItem.additionalOverflowItems` | 两者 | **无** | 溢出菜单（27.1） |
| `presentationPlacement(_:)` / `UISheetPresentationController.preferredPlacement` | 两者 | **无** | sheet 靠边（27.1） |

⚠️ 网上不少资料把 Concentricity 写成 iOS 26 可用，但 26.0 SDK 里 `ConcentricRectangle`
同样查无此符号。**以本机 SDK 为准，不以上述博客为准**。

## 3. 本仓审计结果（Duo 反模式逐条查过）

| Apple 点名的反模式 | 本仓 | 证据 |
|---|---|---|
| 引用 `UIScreen.main` | ✅ 无 | `grep -rn "UIScreen" Mobile/Sources` 零命中 |
| 按方向布局（`UIDevice.orientation` / `interfaceOrientation` / `statusBarOrientation`） | ✅ 无 | 同上，零命中 |
| 按 `userInterfaceIdiom` 分支 | ✅ 无 | 零命中 |
| 按已知机型尺寸硬编码（`bounds.height == 844` 之类） | ✅ 无 | `.frame(width:)` 命中 15 处，全是图标/印章/圆钮/分隔线的固有尺寸（0.5–88pt） |
| 假设左右安全区相等（`width - insets.left * 2`） | ✅ 无 | 悬浮栏走 `.padding(.horizontal, 28)` 叠在系统安全区之内，两侧各自累加 |
| `UIRequiresFullScreen` 锁死 | ✅ 未声明 | `Mobile/MEditorMobile/Info.plist` 无此键（Duo 上仍会随开合改变尺寸，锁它没意义） |
| 居中导致拉伸的固定宽度 | ✅ 已修 | 见 §4 |

## 4. 本次改动（SDK 26 能做的部分）

新增 `Mobile/Sources/Theme/AdaptiveChrome.swift`：三个上限 + 一个 `readableColumn(_:)`
修饰符。**只封顶、不撑开** ⇒ `maxWidth` 在 402pt 的 iPhone 上取原值，
compact 形态零副作用；因此不需要尺寸类分支，也就不存在「尺寸类判断错」这类隐性 bug。

| 上限 | 值 | 理由 |
|---|---|---|
| `readingColumn` | 720pt | 17pt 正文 ≈ 每行 40 汉字 / 75 西文字符 |
| `actionBar` | 620pt | 两条胶囊原本靠 `Spacer` 贴到屏幕两端，1032pt 画布上会拉开 ~900pt |
| `listColumn` | 820pt | 再宽下去「标题 ←→ 日期」的关联就断了 |

落点（6 处）：`RootView` 底部通栏、`DocumentView` 文档动作条 / 纯文本预览 / 编辑器、
`MarkdownPreviewView` 正文、`DocumentHomeView` 列表、`SettingsView` 五个表单。

⚠️ 顺序陷阱：需要通栏背景时 `.background(...)` 必须加在 `readableColumn` **之后**——
该修饰符末尾已经 `frame(maxWidth: .infinity)`，之前加的背景只会铺到封顶宽度那一列。
`SettingsView` 的五个 `Form` 就是照这个顺序重排的。

### 实测（无头模拟器 + 像素量宽，不是目测）

`xcrun simctl` 可以无图形会话截图，再用 PIL 量「墨迹」的横坐标范围：

| 设备（逻辑宽） | 场景 | 内容横跨 | 中心 | 判定 |
|---|---|---|---|---|
| iPad Pro 13"（1032pt，代理内屏尺寸类） | 预览 | 156–876pt（720 宽） | 516 = 1032/2 | 封顶且精确居中 ✅ |
| 同上 | 底部动作栏 | 224–808pt（584 宽） | 516 | 封顶居中 ✅ |
| iPad Pro 13"（非种子，恢复文档） | 预览 | 153–879pt | 516 | 与种子路径一致 ✅ |
| iPhone 17 Pro（402pt） | 预览 | 22.7–379.3pt | — | 仍是 22pt 页边距，**与改前一致** ✅ |
| iPhone 17 Pro（402pt） | 编辑 | 19.3–378pt | — | 14pt `textContainerInset`，**与改前一致** ✅ |

复现命令：

```bash
xcodebuild -project Mobile/MEditorMobile.xcodeproj -scheme MEditorMobile \
  -configuration Debug -destination 'id=<sim-id>' -derivedDataPath /tmp/dd build \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='-disable-sandbox'
xcrun simctl install <sim-id> /tmp/dd/Build/Products/Debug-iphonesimulator/MEditorMobile.app
xcrun simctl launch <sim-id> com.meditor.mobile -debugSeedDocument preview
xcrun simctl io <sim-id> screenshot /tmp/shot.png
```

`-debugSeedDocument preview|edit` 是 **DEBUG-only** 钩子（`MEditorMobileApp.init`，
与既有 `-debugSeedChat` 同款）：建一篇示意文档并直接打开。加它的唯一原因是
`simctl` 没有点击能力——没有它，宽屏布局只能靠肉眼猜。

## 5. 待办：升级到 Xcode 27.1 之后的迁移清单

按收益排序。每条都要先跑 `Build (iOS Simulator)`，再在 DeviceHub 里逐个姿态
（合起 / 展开 / 半折 / 帐篷 / 横竖）截图核对。

### 5.1 内屏侧栏（收益最大）

```swift
// SwiftUI
TabView(selection: $page) { … }
    .defaultTabBarPlacement(.sidebar)      // iOS 27
```

⚠️ 本仓的 tab 栏是 **`.toolbar(.hidden, for: .tabBar)` + 自绘底栏**，所以这条不能直接套。
要么在内屏改用系统侧栏 + 自绘底栏只在 compact 出现，要么保持自绘但改成贴左的竖条。
**先做产品决策，再动代码。**

### 5.2 铰链避让（半折姿态）

```swift
// SwiftUI
GeometryReader { proxy in
    let fold = proxy.reservedRegion(.division, includeInactive: true)
    content.frame(width: proxy.size.width - fold.frame.width)
}
// UIKit
let fold = view.reservedRegion(for: .division, includeInactive: true)
```

内容跨越铰链是 Duo 特有的可读性问题（Apple 的比喻：跨书脊的照片不再是一张完整照片）。
连续滚动的正文**不该位移**，需要位移的是按钮 / 告警 / 分栏。

### 5.3 主次两栏（文档 + AI）

`ArrangementView` / `UIArrangementViewController` 可以按「尺寸类 + 宽高比 + 活动 division
区域」自动在主次两栏之间切换。对本仓最自然的用法：内屏把 AI 面板从 sheet 改成右侧次栏。

### 5.4 工具栏竖排

27.1 起标准导航/工具栏按钮在内屏会走竖排。本仓 `DocumentView` 的 `.principal` 标题 +
`.topBarTrailing` 菜单都是**容器拥有的** bar item，会自动跟随；但 `.principal` 里的
双行标题（文件名 + 字数）在竖排下会被压扁，需要改成 `.horizontalOnly` 或拆成两个 item。

### 5.5 同心圆角

`UICornerConfiguration` 已经在 26.0 可用，但 SwiftUI 侧没有 `ConcentricRectangle`。
卡片目前用固定 `RoundedRectangle(cornerRadius: 14)`，在 Duo 的大圆角屏上会显得不贴边。
等 27 的 `ConcentricRectangle` 再统一改，别现在改成半套。

## 6. 明确不做的事

**不开多场景**（`UIApplicationSupportsMultipleScenes` 保持 `false`）。
Duo 是首款支持「同一 App 多个 UI 实例」的 iPhone，但本仓的 `DocumentStore` / `ChatModel`
是 **App 级 `@State`**（`MEditorMobileApp`），两个窗口会共享同一份 store、同一篇文档，
开关后用户看到的是两个窗口镜像同一篇文档 —— 既不坏也不好。要做就得先把状态下沉到
`WindowGroup` 作用域（`@State` 移进 `RootView`），那是独立的一次重构。

**暂不上 `NavigationSplitView`**（文档列表 + 文档两栏）。它确实是 Apple 推荐的内屏形态，
但本仓导航是 `showDocument` 布尔 + `navigationDestination(isPresented:)`，换成
split view 需要把 `List` 改成 selection 驱动，compact 下的 push 时机也会变。
iOS 没有任何自动化测试，改完只能靠肉眼 —— 等有真机再动。

## 7. 已知短板（这次量出来的）

- `SettingsView` 的五个表单只做了宽度封顶，没有做「内屏两列」。设置项只有十几行，
  两列收益低。
- 底部两条胶囊在 1032pt 上仍在两端（间距 ~290pt），只是不再拉满整屏。要真正「收成一簇」
  需要改信息架构（把「文档 / 设置」切换换成侧栏），属于 5.1 的范围。
