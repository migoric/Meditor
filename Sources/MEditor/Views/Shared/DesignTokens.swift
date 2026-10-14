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
    // 这里曾经有一套 `enum Shadow`（card()/cardRadius/cardY/popoverRadius/popoverY/
    // popoverOpacity，6 个成员，全仓 0 引用），已删除（P0-5）。
    // 删它的理由不是「没用到」而是「半成品会误导」：card() 返回的是**颜色**，
    // 半径/偏移是另一组散落的常量，二者没有绑定关系 —— 任何采纳者都得自己重新
    // 配对，等于每个调用点各写一套。而实际 UI 里的 29 处 `.shadow(...)` 也确实是
    // 各写一套（透明度 0.04–0.45、半径 1–34），说明这套抽象没对上真实需求。
    // 待办（视觉决策，需看界面）：真要做统一抬升语言，应把 color/radius/x/y 绑成一个
    // 值类型（如 `.floatingBar` / `.popover` / `.toast`），再逐处替换并核对观感。

    // MARK: - Semantic Colors
    //
    // 这里保留的是**语义别名**（按 UI 区域命名），不是调色板：用途明确的别名一旦
    // 没人引用，就说明该区域已经改用别的（更合适的）来源，别名本身成了误导。
    // 已删除的三个正是这种情况（P0-5）：
    //   - chromeBg / statusBg —— 已被系统 material 取代（`.background(.bar)`、
    //     `.regularMaterial`）。手抄一组 RGB 反而是降级：丢掉窗口失焦时的自动褪色。
    //   - rowSelected (appAccent.opacity0.13) —— 数值已与实况脱节，实际选中行用的是
    //     appAccent.opacity(0.16)（FileRow.swift:109、FileSidebar.swift:497）与
    //     0.12（FileSidebar.swift:451 等）。留着 0.13 只会诱惑下一个人用错档。
    //     待办（视觉决策，需看界面）：新增一个真正的 row-selection token 并统一这 5 处。
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
