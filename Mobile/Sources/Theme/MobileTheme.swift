import SwiftUI
import UIKit

/// MEditor 移动端设计系统：**GitHub 灰阶骨架 · 单色强调 · 朱砂印记**。
/// 全 App 的颜色 / 字体 / 圆角 / 间距统一从这里取，不在各视图散落字面量。
///
/// 色板来源（两端对齐，2026-10-20 改版）：
/// - 骨架取 GitHub 的 canvas / surface / border / fg 四级灰阶（与 macOS `PreviewTheme.github` 同源）；
/// - 强调色取 shadcn/ui 的 primary 单色（light #18181B / dark #FAFAFA）——不再用彩色承担交互语义；
/// - **朱砂降级为纯品牌印记**：只用于印章（`SealStamp` / `SealCircle`）与 AI 标识点，
///   不再出现在主按钮 / 开关 / 选中态上（此前朱砂是"全页唯一亮色"，也承担全部交互语义）。
///
/// 为什么留朱砂：骨架与强调都中性化之后，唯一的彩色反而比改版前更跳——识别度不靠面积靠稀缺。
/// 为什么链接与图表单独定色：它们曾复用 `accent`，单色化后链接会失去"可点"信号、
/// Mermaid 图会变黑白，故拆出 `link` 与 `diagramAccent` 两个独立 token。
enum PaperTheme {

    // MARK: - 颜色

    /// 色板原始值：Color 与 JS 用 hex 字符串（Hex）均由此派生，改一处全局同步。
    /// 浅色 / 深色两套：Color 走 UIColor 动态色，JS 走 Hex.Light / Hex.Dark。
    fileprivate enum Palette {
        /// 浅色：GitHub light 骨架 + shadcn 单色强调。
        enum Light {
            /// 页面底 —— GitHub canvas-subtle（不是纯白：内容卡要能浮在它上面）。
            static let paper: UInt32          = 0xF6F8FA
            /// 内容卡 / 浮层底 —— 纯白，与 paper 拉开一层。
            static let card: UInt32           = 0xFFFFFF
            /// 正文 —— Craft 近黑（macOS github 主题用的同一档，非纯黑）。
            static let ink: UInt32            = 0x1F2225
            /// 次要文字 —— GitHub fg.muted（白底约 4.7:1）。刻意**不**沿用 macOS 那套的
            /// `#9EA4AA`：那一档在桌面大字号上没问题，但 iOS 上多是 11px 中文小字，偏浅。
            static let inkSecondary: UInt32   = 0x59636E
            /// 强调 —— shadcn primary（近黑）。承担原来朱砂的全部交互语义。
            static let accent: UInt32         = 0x18181B
            /// 强调按压态 —— zinc-700。近黑已到底，按压改为**变浅**（不再像朱砂那样压深）。
            static let accentPressed: UInt32  = 0x3F3F46
            /// 分隔线 / 描边 —— GitHub border-default。
            static let hairline: UInt32       = 0xD1D9E0
            /// 代码块底 —— 比 paper 深一档，在白卡上仍能区分。
            static let codeBackground: UInt32 = 0xEEF1F4
            /// 链接 —— GitHub 链接蓝。单色化后不可复用 accent（否则链接不再像链接）。
            static let link: UInt32           = 0x0969DA
            /// 图表强调 / 描边 —— 中性灰。Mermaid 若用近黑会给每个节点描一圈黑框。
            static let diagramAccent: UInt32  = 0x59636E
            /// 朱砂（品牌印记专用，非交互色）。
            static let seal: UInt32           = 0xC0392B
        }
        /// 深色：GitHub dark 骨架。canvas #0D1117 / surface #161B22 与浅色两级对称。
        enum Dark {
            static let paper: UInt32          = 0x0D1117
            static let card: UInt32           = 0x161B22
            static let ink: UInt32            = 0xE6EDF3
            static let inkSecondary: UInt32   = 0x8B949E
            /// 深色下强调反转为近白（shadcn 的做法）——这是本方案最需要目视确认的一处：
            /// 白块按钮在近黑底上会比浅色模式更抢眼。
            static let accent: UInt32         = 0xFAFAFA
            static let accentPressed: UInt32  = 0xE4E4E7
            static let hairline: UInt32       = 0x30363D
            /// 比 card 亮一档（GitHub neutral-subtle），否则代码块混进卡片里看不见。
            static let codeBackground: UInt32 = 0x21262D
            static let link: UInt32           = 0x4493F8
            static let diagramAccent: UInt32  = 0x8B949E
            /// 深色下朱砂略亮保对比。
            static let seal: UInt32           = 0xD04A3A
        }
    }

    /// 动态 UIColor：浅 / 深两套值按 trait 解析（SwiftUI Color 与 UIKit appearance 共用同一条动态链）。
    static func dynamicUIColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    /// 页面底：GitHub canvas-subtle（浅）/ canvas（深）。内容卡浮在它上面。
    static let paper = Color(light: Palette.Light.paper, dark: Palette.Dark.paper)
    /// 内容卡 / 浮层底：浅色为纯白，深色为 surface —— 与 paper 恒差一层。
    static let card = Color(light: Palette.Light.card, dark: Palette.Dark.card)
    /// 分隔线 / 描边。
    static let hairline = Color(light: Palette.Light.hairline, dark: Palette.Dark.hairline)
    /// 正文（近黑 / 近白）。
    static let ink = Color(light: Palette.Light.ink, dark: Palette.Dark.ink)
    /// 次要文字。
    static let inkSecondary = Color(light: Palette.Light.inkSecondary, dark: Palette.Dark.inkSecondary)
    /// 强调色（shadcn 单色）：主按钮 / FAB / 开关 / 选中态 / 聚焦边框。
    /// 不再使用彩色——朱砂已降级为纯品牌印记（见 `seal`）。
    static let accent = Color(light: Palette.Light.accent, dark: Palette.Dark.accent)
    /// 强调按压态（浅色变浅 / 深色变暗，因为强调色本身已到色阶端点）。
    static let accentPressed = Color(light: Palette.Light.accentPressed, dark: Palette.Dark.accentPressed)
    /// **强调底上的前景色**（shadcn 的 `primary-foreground`）。
    /// 深色模式下 accent 是近白，若沿用 `.white` 前景会白字白底完全不可见——
    /// 所有「accent 作背景」的地方必须用这个而不是 `.white`。
    static let onAccent = Color(light: Palette.Dark.accent, dark: Palette.Light.accent)
    /// 强调色的淡底（选中胶囊 / 标签底）。不能写 `accent.opacity(0.14)`：
    /// 深色下近白的 14% 几乎不可见，两套外观需要不同透明度才等价。
    static let accentSoft = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: Palette.Dark.accent, alpha: 0.16)
            : UIColor(hex: Palette.Light.accent, alpha: 0.10)
    })
    /// 代码块 / 行内代码底。
    static let codeBackground = Color(light: Palette.Light.codeBackground, dark: Palette.Dark.codeBackground)
    /// 链接色：**不可**复用 `accent` —— 单色化后链接会失去"可点"信号。
    static let link = Color(light: Palette.Light.link, dark: Palette.Dark.link)
    /// 页面背景：改版后为**纯色**（原「宣纸纤维」噪点纹理已移除）。
    /// 移除理由：600 点噪点 + `drawingGroup()` 是为米白纸面调的低 opacity，
    /// 压在白底上显灰、压在 #0D1117 上像脏了一层；中性骨架下没有它的位置。
    static var paperBackground: some View {
        paper.ignoresSafeArea()
    }

    /// 卡片柔和投影（替代描边，hairline 只留给真正的分隔线）；墨夜里加重才能看得见。
    /// 卡片柔和投影（替代描边，hairline 只留给真正的分隔线）；墨夜里加重才能看得见。
    static let cardShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.35)
            : UIColor(white: 0, alpha: 0.05)
    })
    /// 朱砂（品牌印记）：**只用于印章与 AI 标识点**，不再承担任何交互语义。
    /// 单色骨架下它是全屏唯一彩色——面积越小越显眼，这是改版后保留品牌识别的方式。
    static let seal = Color(light: Palette.Light.seal, dark: Palette.Dark.seal)

    // MARK: - Hex 字符串（JS / WebView 场景）

    /// 与 Color 同源的 #RRGGBB 字符串：Mermaid 图表等 WKWebView/JS 上下文插值用，
    /// 改 PaperTheme 色板时图表主题自动同步。浅 / 深两套，按当前外观取。
    enum Hex {
        enum Light {
            static let paper          = PaperTheme.hexString(Palette.Light.paper)
            static let card           = PaperTheme.hexString(Palette.Light.card)
            static let ink            = PaperTheme.hexString(Palette.Light.ink)
            static let inkSecondary   = PaperTheme.hexString(Palette.Light.inkSecondary)
            static let diagramAccent  = PaperTheme.hexString(Palette.Light.diagramAccent)
            static let codeBackground = PaperTheme.hexString(Palette.Light.codeBackground)
        }
        enum Dark {
            static let paper          = PaperTheme.hexString(Palette.Dark.paper)
            static let card           = PaperTheme.hexString(Palette.Dark.card)
            static let ink            = PaperTheme.hexString(Palette.Dark.ink)
            static let inkSecondary   = PaperTheme.hexString(Palette.Dark.inkSecondary)
            static let diagramAccent  = PaperTheme.hexString(Palette.Dark.diagramAccent)
            static let codeBackground = PaperTheme.hexString(Palette.Dark.codeBackground)
        }

        /// 一套外观的全部 hex 值：Mermaid 渲染按调用时的 colorScheme 注入（引擎常驻不重建）。
        /// 不含 `accent`：图表已改用 `diagramAccent`（近黑描边会把每个节点描成黑框），
        /// 留着会诱使下一个人拿它当强调色。
        struct Values {
            let paper: String
            let card: String
            let ink: String
            let inkSecondary: String
            /// 图表节点描边 / 连线用的中性灰。
            let diagramAccent: String
            let codeBackground: String
        }

        static func values(dark: Bool) -> Values {
            dark
                ? Values(paper: Dark.paper, card: Dark.card, ink: Dark.ink,
                         inkSecondary: Dark.inkSecondary,
                         diagramAccent: Dark.diagramAccent,
                         codeBackground: Dark.codeBackground)
                : Values(paper: Light.paper, card: Light.card, ink: Light.ink,
                         inkSecondary: Light.inkSecondary,
                         diagramAccent: Light.diagramAccent,
                         codeBackground: Light.codeBackground)
        }
    }

    private static func hexString(_ value: UInt32) -> String {
        String(format: "#%06X", value)
    }

    // MARK: - 圆角

    /// 统一圆角梯度，替换散落的魔法数字。
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xlarge: CGFloat = 20

        /// 卡片 / 浮层。
        static let card: CGFloat = medium
        /// 按钮。
        static let button: CGFloat = medium
        /// 聊天气泡。
        static let bubble: CGFloat = large
    }

    // MARK: - 描边宽度

    /// 描边宽度两档语义（此前 0.5 / 1 散落手写）：
    /// hairline = retina 上 1 物理像素（分隔线 / 内描边），regular = 明确轮廓（卡片 / 控件）。
    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let regular: CGFloat = 1
    }

    // MARK: - 间距

    enum Spacing {
        /// 页面边距（20-24 之间的宽松留白）。
        static let page: CGFloat = 22
    }

    // MARK: - 动效

    /// 全 App 统一的动效曲线：全部为 spring（天然可中断），不在各视图散落 easeOut 魔法数字。
    enum Motion {
        /// 标准：视图切换、指示器滑动、卡片出现。
        static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
        /// 轻快：按压回弹、消息到达、小元素入场。
        static let quick = Animation.spring(response: 0.25, dampingFraction: 0.9)
        /// 舒缓：空态入场、大面积渐变。
        static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.9)
    }

    // MARK: - 字体

    enum Typography {
        /// 品牌大标题（New York 衬线）。
        static func brandTitle(_ size: CGFloat = 34) -> Font {
            .system(size: size, weight: .bold, design: .serif)
        }
        /// UI 层标题（空态标题等）：系统无衬线——衬线只保留给文档内容与品牌字。
        static func uiTitle3() -> Font {
            .system(.title3, weight: .semibold)
        }
        /// Markdown 预览里的衬线标题（全 App 唯一一套标题字号）。
        /// scale：阅读设置的字号系数，层级比例不变。
        static func heading(level: Int, scaledBy scale: CGFloat = 1) -> Font {
            switch level {
            case 1:  return .system(size: 30 * scale, weight: .bold, design: .serif)
            case 2:  return .system(size: 23 * scale, weight: .semibold, design: .serif)
            case 3:  return .system(size: 19 * scale, weight: .semibold, design: .serif)
            default: return .system(size: 17 * scale, weight: .semibold, design: .serif)
            }
        }
        /// 编辑器正文基准字号（阅读设置系数在 MarkdownTextEditor 里乘）。
        static let editorBody = Font.system(size: 16.5, design: .monospaced)
        /// 代码块。scale：阅读设置的字号系数。
        static func code(scaledBy scale: CGFloat = 1) -> Font {
            .system(size: 14.5 * scale, design: .monospaced)
        }
    }
}

// MARK: - Color(hex:) / Color(light:dark:)

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// 动态色：浅 / 墨夜两套 hex，按 trait 解析（底层是 UIColor dynamicProvider，
    /// 转回 UIKit（UIColor(color)）仍保持动态）。
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: PaperTheme.dynamicUIColor(light: light, dark: dark))
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - 可复用样式

/// 通用按压样式：不改动 label 外观，只加按压缩放 / 透明度 / 回弹 / 轻触觉。
/// 用于 tab、头部按钮、chips、操作行等自绘外观的按钮。
/// 注：主按钮已改用 iOS 26 原生 `.buttonStyle(.glassProminent)` + `.tint(accent)`，
/// 原自绘朱砂底 `PaperPrimaryButtonStyle` 随之删除。
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(PaperTheme.Motion.quick, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// 圆形图标按钮（发送 / 停止）：强调色底 + `onAccent` 细线图标，按压缩放 + 转按压态。
/// ⚠️ 前景必须是 `onAccent`——深色下 accent 为近白，`.white` 会白字白底。
struct PaperCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PaperTheme.onAccent)
            .frame(width: size, height: size)
            .background(
                configuration.isPressed ? PaperTheme.accentPressed : PaperTheme.accent,
                in: Circle()
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(PaperTheme.Motion.quick, value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

// MARK: - 朱砂印章

/// 「墨」字朱砂印：落款签名式的品牌标记（空态等场景）。
/// 方形朱底白字、微斜，像盖在名字旁边的一枚真印。
struct SealStamp: View {
    var size: CGFloat = 26

    var body: some View {
        Text("墨")
            .font(.system(size: size * 0.58, weight: .bold, design: .serif))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                PaperTheme.seal,
                in: RoundedRectangle(cornerRadius: size * 0.19, style: .continuous)
            )
            .rotationEffect(.degrees(3))
            .shadow(color: PaperTheme.seal.opacity(0.3), radius: size * 0.15, y: 1.5)
            .accessibilityHidden(true)
    }
}

/// AI 助手的品牌图标：朱砂圆底 + 衬线「墨」，与印章同源的品牌印记。
struct SealCircle: View {
    var size: CGFloat = 46

    var body: some View {
        Text("墨")
            .font(.system(size: size * 0.42, weight: .bold, design: .serif))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(PaperTheme.seal, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - UIKit 外观（导航栏 / 标签栏 / 列表分隔线）

enum PaperAppearance {
    /// 应用启动时调用一次：让系统控件落在与 SwiftUI 同一套色板上。
    /// 颜色全部走动态 UIColor，外观切换（含 App 内手动切换）系统自动重解析。
    @MainActor
    static func apply() {
        typealias Light = PaperTheme.Palette.Light
        typealias Dark = PaperTheme.Palette.Dark
        let inkUIColor = PaperTheme.dynamicUIColor(light: Light.ink, dark: Dark.ink)
        let paperUIColor = PaperTheme.dynamicUIColor(light: Light.paper, dark: Dark.paper)
        let cardUIColor = PaperTheme.dynamicUIColor(light: Light.card, dark: Dark.card)
        let hairlineUIColor = PaperTheme.dynamicUIColor(light: Light.hairline, dark: Dark.hairline)
        let secondaryUIColor = PaperTheme.dynamicUIColor(light: Light.inkSecondary, dark: Dark.inkSecondary)

        // 导航栏：纸底、发丝级分隔；标题用系统无衬线（文档文件名的衬线由 DocumentView 自绘标题承担）。
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = paperUIColor
        nav.shadowColor = hairlineUIColor
        nav.titleTextAttributes = [
            .foregroundColor: inkUIColor,
            .font: UIFont.preferredFont(forTextStyle: .headline),
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: inkUIColor,
            .font: UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .largeTitle).pointSize,
                weight: .bold
            ),
        ]
        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = nav
        navBar.scrollEdgeAppearance = nav
        navBar.compactAppearance = nav

        // 标签栏：卡片底、发丝级顶边、未选中次要色。
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = cardUIColor
        tab.shadowColor = hairlineUIColor
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = secondaryUIColor
            item.normal.titleTextAttributes = [.foregroundColor: secondaryUIColor]
        }
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tab
        tabBar.scrollEdgeAppearance = tab

        // 表单分隔线贴近纸色。
        UITableView.appearance().separatorColor = hairlineUIColor
    }
}
