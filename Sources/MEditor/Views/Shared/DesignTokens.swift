import SwiftUI

// MARK: - Design System Tokens
//
// Single source of truth for all colors, spacing, typography, and motion.
// Use these constants everywhere — never hardcode values in views.

enum DS {

    // MARK: - Spacing (4-pt grid)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner Radius
    enum Radius {
        static let xs:  CGFloat = 3
        static let sm:  CGFloat = 5
        static let md:  CGFloat = 8
        static let lg:  CGFloat = 12
        static let xl:  CGFloat = 16
        static let full: CGFloat = 999
    }

    // MARK: - Stroke Width
    //
    // 描边宽度的两档语义。此前全仓 0.5pt 与 1pt 混用（约 16 处 vs 38 处，同文件
    // 相邻元素也可能不同档），选哪档全凭手感。定为两档：
    //   - hairline：retina 上渲染为 1 物理像素，用于分隔线 / 内描边这类「结构线」；
    //   - regular： 明确的轮廓线，用于卡片 / 控件的边框。
    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let regular:  CGFloat = 1
    }

    // MARK: - Typography
    enum Font {
        /// UI labels, menus
        static func label(_ size: CGFloat = 13, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .default)
        }
        /// Monospaced — status bar, paths, sizes
        static func mono(_ size: CGFloat = 11, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        /// Section headers, panel titles
        static var caption: SwiftUI.Font { .system(size: 11, weight: .medium) }
        static var footnote: SwiftUI.Font { .system(size: 10.5, weight: .regular) }
    }

    // MARK: - Animation
    enum Motion {
        static let micro:    Animation = .easeOut(duration: 0.10)
        static let fast:     Animation = .easeOut(duration: 0.15)
        static let standard: Animation = .easeOut(duration: 0.22)
        static let spring:   Animation = .spring(response: 0.28, dampingFraction: 0.72)
        static let springFast: Animation = .spring(response: 0.18, dampingFraction: 0.75)
        /// Smoother spring for panel slide in/out (sidebar collapse/expand).
        static let panel: Animation = .spring(response: 0.34, dampingFraction: 0.86)
    }

    // MARK: - Elevation
    //
    // 这里曾经有一套 `enum Shadow`（card()/cardRadius/...，6 个成员，全仓 0 引用），
    // 已删（P0-5）。删的理由不是「没用到」而是「半成品会误导」：card() 返回的是**颜色**，
    // 半径/偏移另写在散落的常量里，二者没有绑定关系 —— 采纳者仍得自己配对。
    //
    // 2026-10-17 补上真的实现：color / radius / y 绑成一个值，一处改、处处改。
    // 档位按**用途**命名而非尺寸阶梯 —— 实测 29 处 `.shadow(...)` 的选择依据是
    // 「这是什么层」（浮条 / 提示 / 弹出 / hero），不是「多大」。
    //
    // 22 处已收敛，**7 处刻意保留**（形态不同，硬塞会丢信息）：
    //   · 3 处接触阴影（launcher r2/y1、@mention r4/y2、tab bar r1/y0）—— 与主阴影成对
    //   · 2 处品牌发光（AIInputBar 的 accent glow、WelcomeView 的 accent/aurora 光晕）
    //     —— 不是 elevation，是与强调色绑定的视觉反馈
    //   · 1 处尺寸相关（SettingsComponents 的 `size * 0.18`）
    //   · 1 处条件式（TemplateCard 的 hover 分级）—— 已映射为 `.toast` / `.floatingBar`
    //
    // 取值口径：各类原值的中位数。深色档显著重于浅色档，沿用原代码里普遍的
    // `dark ? 0.40 : 0.12` 比例关系。
    enum Elevation {
        case floatingBar   // 浮条 / 内联编辑条 / 工具栏胶囊
        case toast         // 轻提示
        case popover       // 弹出层 / 候选列表
        case hero          // 大浮层 / 启动器展开

        /// (color, radius, y)
        func components(dark: Bool) -> (SwiftUI.Color, CGFloat, CGFloat) {
            switch self {
            case .floatingBar: return (.black.opacity(dark ? 0.40 : 0.12), 6, 2)
            case .toast:       return (.black.opacity(dark ? 0.30 : 0.14), 10, 3)
            case .popover:     return (.black.opacity(dark ? 0.42 : 0.18), 18, 7)
            case .hero:        return (.black.opacity(dark ? 0.42 : 0.30), 28, 13)
            }
        }
    }

    // MARK: - Semantic Colors
    //
    // 这里保留的是**语义别名**（按 UI 区域命名），不是调色板：用途明确的别名一旦
    // 没人引用，就说明该区域已经改用别的（更合适的）来源，别名本身成了误导。
    // 已删除的三个正是这种情况（P0-5）：
    //   - chromeBg / statusBg —— 已被系统 material 取代（`.background(.bar)`、
    //     `.regularMaterial`）。手抄一组 RGB 反而是降级：丢掉窗口失焦时的自动褪色。
    //   - rowSelected (appAccent.opacity0.13) —— 数值已与实况脱节。
    //     2026-10-17 已补上真正的 row-selection token（`selectionFill`）并统一了全部
    //     10 处选中态底色：此前实际是四档并存（0.12×5 / 0.13×1 / 0.15×4 / 0.16×2，
    //     原注释只记了其中两档共 5 处，是不完整的）。装饰性光晕（WelcomeView.cardGlow、
    //     CalendarGridViews 的今日圆点）不属选中态，未并入。
    enum Color {
        /// Sidebar background — slightly offset from editor
        static var sidebarBg: SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0.135, alpha: 1)
                    : NSColor(white: 0.952, alpha: 1)
            })
        }

        /// Editor background
        static var editorBg: SwiftUI.Color {
            SwiftUI.Color(nsColor: .textBackgroundColor)
        }

        /// Divider between panels
        static var divider: SwiftUI.Color {
            SwiftUI.Color.primary.opacity(0.08)
        }

        /// File row hover
        static var rowHover: SwiftUI.Color {
            SwiftUI.Color.primary.opacity(0.055)
        }

        /// Status bar pill background
        static var pillBg: SwiftUI.Color {
            SwiftUI.Color.primary.opacity(0.06)
        }

        /// Row / item selection fill —— 所有「选中态底色」的唯一来源。
        ///
        /// 取 0.14 是因为它是 2026-10 实测原值的中位数：0.12×5 / 0.13×1 / 0.15×4 / 0.16×2。
        /// 统一后每个调用点的偏移 ≤0.02，肉眼不可辨 —— 目的不是换个好看的值，而是消掉
        /// 四档并存（同一件事写四遍，下一个人只会再发明第五档）。
        static var selectionFill: SwiftUI.Color {
            SwiftUI.Color.appAccent.opacity(0.14)
        }
    }
}

// MARK: - View Modifiers

/// Micro-interaction hover brightness shift
struct HoverBrightness: ViewModifier {
    @State private var hovered = false
    var amount: Double

    func body(content: Content) -> some View {
        content
            .brightness(hovered ? amount : 0)
            .onHover { hovered = $0 }
            .animation(DS.Motion.micro, value: hovered)
    }
}

extension View {
    func hoverBrightness(_ amount: Double = 0.06) -> some View {
        modifier(HoverBrightness(amount: amount))
    }
}

/// 应用统一抬升。
///
/// 明暗走系统 `colorScheme` 而非 `theme.isDark`：阴影属于窗口 chrome，跟随系统外观。
/// 若将来要让 chrome 跟随预览主题，改这一处判断即可 —— 所有调用点会一次性跟着变，
/// 而不是像以前那样每处各判断一次（那正是这套 token 想解决的重复）。
struct DSElevationModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let level: DS.Elevation

    func body(content: Content) -> some View {
        let (color, radius, y) = level.components(dark: colorScheme == .dark)
        return content.shadow(color: color, radius: radius, x: 0, y: y)
    }
}

extension View {
    /// 统一抬升：`.dsElevation(.floatingBar)` / `.toast` / `.popover` / `.hero`
    func dsElevation(_ level: DS.Elevation) -> some View {
        modifier(DSElevationModifier(level: level))
    }
}

/// Accent selection indicator (left edge line)
struct SelectionAccentLine: View {
    var color: SwiftUI.Color = .appAccent
    var verticalPad: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 2.5)
            .padding(.vertical, verticalPad)
    }
}

/// Status-bar pill capsule
struct StatusPill: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
            }
            Text(text)
                .font(DS.Font.mono(10.5))
                .kerning(-0.2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Capsule()
                .fill(DS.Color.pillBg)
        )
    }
}
