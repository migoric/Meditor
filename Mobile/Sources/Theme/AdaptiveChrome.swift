import SwiftUI

/// 宽画布（iPhone Duo 内屏 / iPad）的布局上限，以及折叠屏「铰链」的避让。
///
/// 为什么只封顶、不按机型或尺寸类分支：
/// - Apple 对 iPhone Duo 的布局要求只有一条硬约束——**按尺寸类布局，不看方向、不看 idiom**。
///   内屏（7.6"）是 regular × regular，外屏（5.4"）与普通 iPhone 一致，且内屏
///   **不遵循** `UISupportedInterfaceOrientations`：展开后 `UIDevice.orientation`、
///   `windowScene.effectiveGeometry.interfaceOrientation` 都不再等价于窗口形状。
/// - `maxWidth` 只封顶、不撑开：393pt 的 iPhone 上取的就是原值 ⇒ compact 下零副作用。
///   所以这里不需要 `horizontalSizeClass` 分支，也就不存在「尺寸类判断错」这类隐性 bug。
///
/// 铰链避让只作用于**成簇的 chrome**（底部动作栏这类「一组控件」），不作用于连续滚动的正文——
/// 正文跨过折痕只是看着别扭，位移反而会打断阅读（`docs/iphone-duo.md` §5.2）。
enum AdaptiveChrome {
    /// 正文可读宽度上限（pt）。17pt 正文 ≈ 每行 40 个汉字 / 75 个西文字符。
    /// 没有它时，7.6" 内屏展开后正文栏会拉到 1000pt 以上，一行能塞 90 个汉字。
    static let readingColumn: CGFloat = 720

    /// 悬浮动作栏（两条胶囊）的最大宽度。原实现靠 `Spacer` 把两簇贴到屏幕两侧，
    /// 宽画布上两者会拉开 ~900pt，视觉上不再是一组控件。
    static let actionBar: CGFloat = 620

    /// 文档列表 / 设置表单的最大宽度。列表行再宽下去，标题与右侧日期的关联就断了。
    static let listColumn: CGFloat = 820

    /// 铰链两侧各留的余量（pt）。chrome 紧贴折痕会看起来「骑」在铰链上。
    static let hingeClearance: CGFloat = 12

    /// 半折姿态下语义上仍允许放控件的最小宽度（pt）。两侧都窄于此值时不再硬塞，
    /// 交给 `min` 兜底——宁可压扁也不要把控件推到折痕外面。
    static let minimumChromeSpan: CGFloat = 120

    /// 把「被铰链占用的横坐标区间」切成若干连续可用区间（升序）。
    ///
    /// 纯函数，不碰 SwiftUI：`scripts/verify_hinge_math.swift` 直接跑它做断言
    /// （iOS 侧没有测试 target，几何计算只能这样钉住）。
    static func freeSpans(width: CGFloat, dividers: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        guard width > 0 else { return [] }
        var spans: [ClosedRange<CGFloat>] = []
        var cursor: CGFloat = 0
        // 相交 / 相邻的 division 先合并，否则会切出宽度为 0 的碎片。
        for divider in dividers.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = max(0, divider.lowerBound)
            let upper = min(width, divider.upperBound)
            guard upper > lower else { continue }
            if lower > cursor {
                spans.append(cursor...lower)
            }
            cursor = max(cursor, upper)
        }
        if cursor < width {
            spans.append(cursor...width)
        }
        return spans
    }
}

// MARK: - 系统 bar 竖排形态（iPhone Duo 外屏 / 内屏横排）

extension EnvironmentValues {
    /// 当前上下文里系统是否把 bar 竖排（Duo 外屏、内屏横排；内屏竖排仍是横向）。
    ///
    /// 由 `RootView` 的探针写入，供子视图决定「自绘 chrome 要不要让位给系统 tab 栏」。
    /// 判据不是尺寸类、也不是机型——按 HIG，只有「系统是不是竖排」这一个事实，
    /// 来源就是 `toolbarVerticalEdge`（见下）。
    @Entry var verticalChrome: Bool = false
}

/// 读出 `toolbarVerticalEdge` 再渲染内容。
///
/// 为什么用这个环境值：Apple《Preparing your app for iPhone Duo》对**自绘视图**明确写了
/// “In a custom view, you may need to know if the system presents bars vertically…
/// use the `toolbarVerticalEdge` environment value”。本仓的底栏是自绘的（`.toolbar(.hidden)`
/// 藏了系统 tab 栏），系统不会替我们搬——所以只能自己问到这个事实，再把 bar 换成系统的那条。
///
/// iOS 27.1 之前没有这个值，一律按「横向」处理，行为与改动前逐像素一致。
struct VerticalChromeProbe<Content: View>: View {
    @ViewBuilder let content: (_ vertical: Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            _VerticalChromeProbe(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct _VerticalChromeProbe<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let content: (_ vertical: Bool) -> Content

    var body: some View {
        content(edge != nil)
    }
}

// MARK: - 底部悬浮栏留白

extension View {
    /// 给可滚动内容补「底部悬浮栏」留白。
    ///
    /// 竖排 bar 形态（Duo 外屏 / 内屏横排）下没有自绘悬浮栏——那块空间交给系统 tab 栏，
    /// 安全区由系统处理——所以留白归零，否则列表/正文末尾会多出一截空白。
    func bottomBarContentInset(verticalChrome: Bool) -> some View {
        contentMargins(
            .bottom,
            verticalChrome ? 0 : PaperTheme.Spacing.bottomBarInset,
            for: .scrollContent
        )
    }
}

// MARK: - 铰链几何

extension ClosedRange where Bound == CGFloat {
    /// 区间宽度（pt）。`ClosedRange` 自身没有 `.width`，只有 `CGRect` 有。
    fileprivate var spanWidth: CGFloat { upperBound - lowerBound }
}

/// 当前窗口的**铰链切分**。没有 folds 的设备上恒为 `.none`，所有取值退化成「不位移」。
struct HingeLayout: Equatable, Sendable {
    /// 窗口宽度（pt）。0 表示尚未完成首次布局。
    var containerWidth: CGFloat = 0
    /// 铰链占用的横坐标区间（窗口坐标系）。空 = 无铰链 / 未展开 / 系统未上报。
    var dividers: [ClosedRange<CGFloat>] = []
    /// 安全区左右内缩（pt）。诊断用：Duo 外屏实测右侧有 84pt 保留区，
    /// 所以「外屏 = 整幅 466pt」是错的，可用宽度只有 382pt。
    var safeLeading: CGFloat = 0
    var safeTrailing: CGFloat = 0
    /// 摄像头 / 遮挡区（窗口坐标系）。只做诊断，不参与 chrome 位移——
    /// 本仓的 chrome 都落在底部，不会被顶部挖孔压到。
    var occlusions: [ClosedRange<CGFloat>] = []

    static let none = HingeLayout()

    var isSplit: Bool { !dividers.isEmpty }

    /// 连续可用区间。无铰链时就是整幅窗口。
    var freeSpans: [ClosedRange<CGFloat>] {
        isSplit ? AdaptiveChrome.freeSpans(width: containerWidth, dividers: dividers)
                : (containerWidth > 0 ? [0...containerWidth] : [])
    }

    /// 最宽的那块连续区域——chrome 只往这里放。
    /// 宽度相等时取**靠左**的一块（居中铰链会切出两块等宽区域，不定义次序就成了随机行为）。
    var widestSpan: ClosedRange<CGFloat> {
        freeSpans.max { lhs, rhs in
            lhs.spanWidth != rhs.spanWidth ? lhs.spanWidth < rhs.spanWidth
                                           : lhs.lowerBound > rhs.lowerBound
        } ?? 0...containerWidth
    }

    /// chrome 的封顶宽度与横移量。无铰链时 `offset == 0`、`width == cap`，与改动前完全一致。
    func chromeSpan(cap: CGFloat) -> (width: CGFloat, offset: CGFloat) {
        guard isSplit, containerWidth > 0 else { return (cap, 0) }
        let span = widestSpan
        let usable = max(AdaptiveChrome.minimumChromeSpan,
                         span.spanWidth - AdaptiveChrome.hingeClearance * 2)
        let spanCenter = (span.lowerBound + span.upperBound) / 2
        return (min(cap, usable), spanCenter - containerWidth / 2)
    }

    /// 从 `GeometryProxy` 读出铰链。`reservedRegions(kind:options:)` 是 iOS 27.1 起才有的 API，
    /// 部署目标是 26.0，所以必须运行期判断——低版本上拿不到铰链，退化成「整幅窗口」。
    static func measure(_ proxy: GeometryProxy) -> HingeLayout {
        var layout = HingeLayout(containerWidth: proxy.size.width)
        layout.safeLeading = proxy.safeAreaInsets.leading
        layout.safeTrailing = proxy.safeAreaInsets.trailing
        if #available(iOS 27.1, *) {
            // 默认只取**活跃**的 division：帐篷 / 合起姿态下铰链不切分可用区域，不该位移。
            layout.dividers = proxy.reservedRegions(kind: .division).compactMap { region in
                let frame = region.frame
                guard frame.width > 0, frame.height > 0 else { return nil }
                return frame.minX...(frame.minX + frame.width)
            }
            layout.occlusions = proxy.reservedRegions(kind: .occlusion).compactMap { region in
                let frame = region.frame
                guard frame.width > 0, frame.height > 0 else { return nil }
                return frame.minX...(frame.minX + frame.width)
            }
        }
        return layout
    }
}

// MARK: - 修饰符

extension View {
    /// 可读宽度封顶 + 水平居中。**用于连续内容**（正文、表单、列表）：不避让铰链。
    ///
    /// ⚠️ 需要通栏背景时，`.background(...)` 必须加在这个 modifier **之后**
    ///（modifier 末尾已经 `frame(maxWidth: .infinity)`，之后加的背景才是通栏的）。
    func readableColumn(_ maxWidth: CGFloat) -> some View {
        modifier(ReadableColumn(maxWidth: maxWidth))
    }

    /// chrome 宽度封顶 + 居中到**最宽的连续区域**。用于成簇控件（底部动作栏）。
    func chromeColumn(_ maxWidth: CGFloat) -> some View {
        modifier(ChromeColumn(maxWidth: maxWidth))
    }
}

private struct ReadableColumn: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

private struct ChromeColumn: ViewModifier {
    let maxWidth: CGFloat

    /// 就地测量，而不是从 `RootView` 注入。
    ///
    /// 踩过的坑：在 `RootView` 的 ZStack 上 `onGeometryChange` 拿到的是 **382pt**，
    /// 而窗口真实宽度是 **466pt** —— Duo 外屏把右侧 84pt 划进了安全区，但底栏本身
    /// 是铺满 466pt 的。把「宽度」和「铰链坐标」分开量，`spanCenter - W/2` 会差 42pt。
    /// 所以这里在 chrome **自己的容器**上量：两者必然同源。
    @State private var layout = HingeLayout.none

    func body(content: Content) -> some View {
        let span = layout.chromeSpan(cap: maxWidth)
        return content
            .frame(maxWidth: span.width)
            .frame(maxWidth: .infinity)
            // 位移只影响绘制，不影响命中区域所在的布局槽位——底栏本来就是浮层，可接受。
            .offset(x: span.offset)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onGeometryChange(for: HingeLayout.self) { HingeLayout.measure($0) } action: { layout = $0 }
                }
            }
    }
}

// MARK: - 布局探针（仅 DEBUG）

#if DEBUG
/// 把当前几何与铰链读数画在屏幕左上角，用于模拟器 / 真机姿态走查。
///
/// 为什么需要它：`simctl` 没有点击能力，也没有**切姿态**的能力（Xcode 27 用 DeviceHub
/// 取代了 Simulator.app，折叠姿态只能手动开合）。没有这块探针，铰链相关的改动在
/// 自动截图里永远看不见——只能靠人眼看「好像没变」。
///
/// 打开方式：`xcrun simctl launch <dev> com.meditor.mobile -debugLayoutProbe YES`
struct LayoutProbeOverlay: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale

    @State private var layout = HingeLayout.none

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("w \(Self.fmt(layout.containerWidth)) safe \(Self.fmt(layout.safeLeading))/\(Self.fmt(layout.safeTrailing)) · \(sizeClassText) · \(Self.fmt(displayScale))x")
            Text("div \(layout.dividers.count) · \(Self.rangeText(layout.dividers)) · split \(layout.isSplit ? "Y" : "N")")
            Text("occ \(layout.occlusions.count) · \(Self.rangeText(layout.occlusions))")
            Text("span \(Self.rangeText([layout.widestSpan]))")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.top, 54)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        // 与 `ChromeColumn` 同一套测量：探针只报告**自己所在这块区域**的几何。
        // 它和底栏不一定同宽（Duo 外屏安全区比窗口窄 84pt），看数字时要带上 `safe`。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onGeometryChange(for: HingeLayout.self) { HingeLayout.measure($0) } action: { layout = $0 }
            }
        }
    }

    private var sizeClassText: String {
        let horizontal = horizontalSizeClass == .regular ? "reg" : "cmp"
        let vertical = verticalSizeClass == .regular ? "reg" : "cmp"
        return "\(horizontal)×\(vertical)"
    }

    private static func rangeText(_ ranges: [ClosedRange<CGFloat>]) -> String {
        guard !ranges.isEmpty else { return "—" }
        return ranges
            .map { "\(fmt($0.lowerBound))–\(fmt($0.upperBound))" }
            .joined(separator: " ")
    }

    private static func fmt(_ value: CGFloat) -> String {
        String(format: "%.0f", value)
    }
}
#endif
