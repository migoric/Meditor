import SwiftUI

/// A left-side outline showing document headings for quick navigation.
struct TOCOutlineView: View {
    let items: [TOCItem]
    let theme: PreviewTheme
    let activeLineIndex: Int
    let isLoading: Bool
    let onSelect: (TOCItem) -> Void

    /// 滚动内容顶部 y（named 坐标系内），< 0 表示已向下滚动。
    @State private var scrollMinY: CGFloat = 0

    var body: some View {
        // macOS 26：detail 列通顶到窗口顶缘（toolbar 是 52pt 透明玻璃），
        // ScrollView 的 frame 碰到顶部安全区后，滚动内容会延伸进横带。
        // 处理：frame 顶缘停在 tab 胶囊下缘（安全区 - 14pt），配合 .hard
        // 在 frame 顶缘硬裁剪。系统的自动安全区内边距/边缘渐隐都不可靠
        // （内边距让初始内容过低，.soft 会把初始内容也淡化），所以渐隐
        // 完全自己做：仅在发生滚动后，在 frame 顶部盖一条栏背景色的渐变
        // 遮罩，未滚动时遮罩不存在，初始内容永远是不透明的。
        GeometryReader { geo in
            outlineList
                .overlay(alignment: .top) { topFadeOverlay }
                .padding(.top, topClipOffset(geo))
        }
        // 平面化（Apple 备忘录式）：TOC 是预览左缘的一个普通栏，
        // 背景和右侧分隔线由 PreviewPanel 提供，不再自成悬浮卡片。
    }

    /// 滚动后才出现的顶部渐隐遮罩：栏背景色 → 透明，盖在裁剪线下方 14pt，
    /// 让滚上去的内容「溶进」栏背景而不是撞上硬边。
    private var topFadeOverlay: some View {
        LinearGradient(
            colors: [theme.editorBackground, theme.editorBackground.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 14)
        .frame(maxWidth: .infinity)
        .opacity(scrollMinY < -1 ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: scrollMinY < -1)
        .allowsHitTesting(false)
    }

    /// macOS 26+ 躲开 toolbar 横带但吃回其下部 14pt；旧系统 detail 列本来就
    /// 从 toolbar 下方开始布局（顶部安全区为 0），不需要额外内边距。
    private func topClipOffset(_ geo: GeometryProxy) -> CGFloat {
        if #available(macOS 26.0, *) {
            return max(0, geo.safeAreaInsets.top - 14)
        }
        return 0
    }

    private var outlineList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // 滚动位置探针：把内容顶部 y 通过 preference 报出去
                    GeometryReader { probe in
                        Color.clear.preference(
                            key: TOCScrollOffsetKey.self,
                            value: probe.frame(in: .named(Self.scrollSpace)).minY
                        )
                    }
                    .frame(width: 0, height: 0)

                    Text("OUTLINE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                        .padding(.bottom, 8)

                    if items.isEmpty {
                        TOCPlaceholder(theme: theme, isLoading: isLoading)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            Button {
                                onSelect(item)
                            } label: {
                                TOCRow(
                                    item: item,
                                    isActive: idx == activeLineIndex,
                                    previousLevel: idx > 0 ? items[idx - 1].level : nil
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(L("toc.level", item.level))
                            .id(idx)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onPreferenceChange(TOCScrollOffsetKey.self) { scrollMinY = $0 }
            .onChange(of: activeLineIndex) { _, newIdx in
                guard newIdx >= 0 else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }
        }
        // frame 顶缘伸进了 toolbar 横带（见 body 注释）——用 .hard 在 frame
        // 顶缘硬裁剪。注意不要用 .soft：渐隐按「距 frame 顶缘的距离」生效，
        // 初始（未滚动）内容也在渐隐区内，会被误伤成半透明。
        // 也不要传 .none：参数是 Optional，.none = nil = 系统默认效果。
        .topScrollEdgeHardClipIfAvailable()
        .accessibilityLabel(L("rightPanel.outline"))
    }

    private static let scrollSpace = "tocOutlineScroll"
}

/// TOC 滚动位置 preference（内容顶部在 named 坐标系中的 minY）。
private struct TOCScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TOCPlaceholder: View {
    let theme: PreviewTheme
    let isLoading: Bool

    private let widths: [CGFloat] = [0.78, 0.62, 0.7, 0.54]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { idx, width in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(opacity(for: idx)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(width: width * 156, height: height(for: idx), alignment: .leading)
                    .padding(.leading, leadingInset(for: idx))
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 52, height: 8)
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func opacity(for index: Int) -> Double {
        isLoading ? 0.08 - (Double(index) * 0.01) : 0.05 - (Double(index) * 0.006)
    }

    private func height(for index: Int) -> CGFloat {
        index == 0 ? 10 : 8
    }

    private func leadingInset(for index: Int) -> CGFloat {
        switch index {
        case 1: return 12
        case 2: return 24
        case 3: return 12
        default: return 0
        }
    }
}

private struct TOCRow: View {
    let item: TOCItem
    let isActive: Bool
    let previousLevel: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear
                .frame(width: indentation)

            Text(item.title)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(foregroundStyle)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .truncationMode(.tail)
                .lineSpacing(1.2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(backgroundStyle)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isActive ? Color.appAccent : levelStripeColor)
                        .frame(width: stripeWidth)
                        .padding(.vertical, 5)
                        .opacity(isActive || item.level >= 3 ? 1 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, topSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private var indentation: CGFloat {
        CGFloat((item.level - 1).clamped(to: 0...5)) * 12
    }

    private var topSpacing: CGFloat {
        guard let previousLevel else { return 0 }
        if item.level == 1 {
            return 8
        }
        if item.level <= previousLevel {
            return item.level == 2 ? 6 : 3
        }
        return 2
    }

    private var fontSize: CGFloat {
        switch item.level {
        case 1: return 12.5
        case 2: return 11.5
        default: return 10.5
        }
    }

    private var fontWeight: Font.Weight {
        if isActive { return .semibold }
        switch item.level {
        case 1: return .semibold
        case 2: return .medium
        default: return .regular
        }
    }

    private var verticalPadding: CGFloat {
        switch item.level {
        case 1: return 7
        case 2: return 6
        default: return 5
        }
    }

    private var backgroundStyle: some ShapeStyle {
        if isActive {
            return Color.appAccent.opacity(0.09)
        }
        return Color.clear
    }

    private var foregroundStyle: some ShapeStyle {
        if isActive {
            return Color.primary
        }
        switch item.level {
        case 1:
            return Color.primary.opacity(0.8)
        case 2:
            return Color.primary.opacity(0.62)
        default:
            return Color.secondary.opacity(0.95)
        }
    }

    private var levelStripeColor: Color {
        Color.secondary.opacity(0.14)
    }

    private var stripeWidth: CGFloat {
        isActive ? 3 : 1
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension View {
    /// 在 scroll view 的 frame 顶缘对滚动内容做硬裁剪（macOS 26）。
    /// 注意参数是 Optional<ScrollEdgeEffectStyle>——传 `.none` 会被解析成
    /// nil（= automatic），不是「关闭效果」。
    /// #if compiler 守卫：API 只在 macOS 26 SDK（Xcode 26 / Swift 6.2）里存在。
    @ViewBuilder
    func topScrollEdgeHardClipIfAvailable() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
