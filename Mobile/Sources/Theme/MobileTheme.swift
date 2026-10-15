import SwiftUI
import UIKit

/// MEditor 移动端「纸墨」设计系统：宣纸白 · 松烟墨 · 朱砂印。
/// 全 App 的颜色 / 字体 / 圆角 / 间距统一从这里取，不在各视图散落字面量。
enum PaperTheme {

    // MARK: - 颜色

    /// 色板原始值：Color 与 JS 用 hex 字符串（Hex）均由此派生，改一处全局同步。
    /// 宣纸白 · 松烟墨 · 朱砂印 的纸墨色板 + Craft 式组件语言（胶囊/白卡/浮起）。
    /// 浅色 / 墨夜（深色）两套：Color 走 UIColor 动态色，JS 走 Hex.Light / Hex.Dark。
    fileprivate enum Palette {
        enum Light {
            static let paper: UInt32          = 0xF4F5F2
            static let card: UInt32           = 0xFFFFFF
            static let ink: UInt32            = 0x1B2434
            static let inkSecondary: UInt32   = 0x5D6673
            static let accent: UInt32         = 0xC0392B
            static let accentPressed: UInt32  = 0x9E2E22
            static let hairline: UInt32       = 0xE2E6E1
            static let codeBackground: UInt32 = 0xECEFEA
        }
        /// 墨夜：墨黑泛蓝的底（不用纯黑），宣纸白字微暖，朱砂略亮保对比。
        enum Dark {
            static let paper: UInt32          = 0x14181F
            static let card: UInt32           = 0x1C222C
            static let ink: UInt32            = 0xE8E4DC
            static let inkSecondary: UInt32   = 0x8B93A1
            static let accent: UInt32         = 0xD04A3A
            static let accentPressed: UInt32  = 0xA83A2C
            static let hairline: UInt32       = 0x2A3140
            static let codeBackground: UInt32 = 0x232A37
        }
    }

    /// 动态 UIColor：浅 / 深两套值按 trait 解析（SwiftUI Color 与 UIKit appearance 共用同一条动态链）。
    static func dynamicUIColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    /// 宣纸背景（页面底）：冷调米白，带一丝纸纤维的青灰；墨夜为墨黑泛蓝。
    static let paper = Color(light: Palette.Light.paper, dark: Palette.Dark.paper)
    /// 卡片 / 浮层底（比宣纸更白一度，拉开色阶）。
    static let card = Color(light: Palette.Light.card, dark: Palette.Dark.card)
    /// 冷灰分隔线 / 描边。
    static let hairline = Color(light: Palette.Light.hairline, dark: Palette.Dark.hairline)
    /// 松烟墨正文（蓝黑，不是暖棕黑）；墨夜反转为宣纸白。
    static let ink = Color(light: Palette.Light.ink, dark: Palette.Dark.ink)
    /// 次要文字（青灰）。
    static let inkSecondary = Color(light: Palette.Light.inkSecondary, dark: Palette.Dark.inkSecondary)
    /// 朱砂（印章红）：全页唯一亮色——主按钮 / 选中态 / 开关 / FAB。墨夜里略亮保对比。
    static let accent = Color(light: Palette.Light.accent, dark: Palette.Dark.accent)
    /// 朱砂按压态。
    static let accentPressed = Color(light: Palette.Light.accentPressed, dark: Palette.Dark.accentPressed)
    /// 代码块 / 行内代码的浅色底（比纸面略深，保持同色系）。
    static let codeBackground = Color(light: Palette.Light.codeBackground, dark: Palette.Dark.codeBackground)
    /// 宣纸纤维纹理：Canvas 绘制确定性噪点 + 极淡竖纹渐变，GPU 光栅化缓存。
    /// 噪点使用固定种子（seed=42），每屏约 600 个随机纤维点，深浅两套 opacity。
    static var paperBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(light: 0xF7F8F4, dark: 0x161B23),
                    Color(light: 0xEFF1EC, dark: 0x11151C),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            PaperNoiseOverlay()
        }
    }

    /// 卡片柔和投影（替代描边，hairline 只留给真正的分隔线）；墨夜里加重才能看得见。
    /// 卡片柔和投影（替代描边，hairline 只留给真正的分隔线）；墨夜里加重才能看得见。
    static let cardShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.35)
            : UIColor(white: 0, alpha: 0.05)
    })
    /// 朱砂印章红（品牌印记，不随交互蓝变化）：仅 SealStamp 与品牌场景使用。
    static let seal = Color(light: 0xC0392B, dark: 0xD04A3A)

    // MARK: - Hex 字符串（JS / WebView 场景）

    /// 与 Color 同源的 #RRGGBB 字符串：Mermaid 图表等 WKWebView/JS 上下文插值用，
    /// 改 PaperTheme 色板时图表主题自动同步。浅 / 深两套，按当前外观取。
    enum Hex {
        enum Light {
            static let paper          = PaperTheme.hexString(Palette.Light.paper)
            static let card           = PaperTheme.hexString(Palette.Light.card)
            static let ink            = PaperTheme.hexString(Palette.Light.ink)
            static let inkSecondary   = PaperTheme.hexString(Palette.Light.inkSecondary)
            static let accent         = PaperTheme.hexString(Palette.Light.accent)
            static let codeBackground = PaperTheme.hexString(Palette.Light.codeBackground)
        }
        enum Dark {
            static let paper          = PaperTheme.hexString(Palette.Dark.paper)
            static let card           = PaperTheme.hexString(Palette.Dark.card)
            static let ink            = PaperTheme.hexString(Palette.Dark.ink)
            static let inkSecondary   = PaperTheme.hexString(Palette.Dark.inkSecondary)
            static let accent         = PaperTheme.hexString(Palette.Dark.accent)
            static let codeBackground = PaperTheme.hexString(Palette.Dark.codeBackground)
        }

        /// 一套外观的全部 hex 值：Mermaid 渲染按调用时的 colorScheme 注入（引擎常驻不重建）。
        struct Values {
            let paper: String
            let card: String
            let ink: String
            let inkSecondary: String
            let accent: String
            let codeBackground: String
        }

        static func values(dark: Bool) -> Values {
            dark
                ? Values(paper: Dark.paper, card: Dark.card, ink: Dark.ink,
                         inkSecondary: Dark.inkSecondary, accent: Dark.accent,
                         codeBackground: Dark.codeBackground)
                : Values(paper: Light.paper, card: Light.card, ink: Light.ink,
                         inkSecondary: Light.inkSecondary, accent: Light.accent,
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

// MARK: - 宣纸纤维纹理（确定性噪点）

/// 用 Canvas 在纸面上绘制微小的纤维纹理点，模拟宣纸的天然质感。
/// 使用固定种子（seed=42），位置和透明度均确定，不随刷新改变。
/// 简化的确定性伪随机（线性同余），仅用于 PaperNoiseOverlay 的纤维分布。
private struct LCG {
    private var state: UInt64
    init(seed: UInt64 = 42) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state) / Double(UInt64.max)
    }
}

private struct PaperNoiseOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 预计算的纤维点：相对坐标(0~1) + 透明度 → 600 点覆盖全屏。
    private static let fibers: [(x: Double, y: Double, opacity: Double)] = {
        var rng = LCG()
        return (0..<600).map { _ in (rng.next(), rng.next(), rng.next() * 0.025 + 0.005) }
    }()

    var body: some View {
        Canvas { ctx, size in
            let tint = colorScheme == .dark ? Color.white : Color.black
            for f in Self.fibers {
                let pt = CGPoint(x: f.x * size.width, y: f.y * size.height)
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x, y: pt.y, width: 0.5, height: 0.5)),
                         with: .color(tint.opacity(f.opacity)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - 可复用样式

/// 通用按压样式：不改动 label 外观，只加按压缩放 / 透明度 / 回弹 / 轻触觉。
/// 用于 tab、头部按钮、chips、操作行等自绘外观的按钮。
/// 注：主按钮已改用 iOS 26 原生 `.buttonStyle(.glassProminent)` + `.tint(朱砂)`，
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

/// 圆形图标按钮（发送 / 停止）：强调色底白色细线图标，按压缩放 + 转深色。
struct PaperCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
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
    /// 应用启动时调用一次：让系统控件也落在纸墨色系里。
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
