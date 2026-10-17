import SwiftUI

/// Reports the source button's bounds so the settings panel can "grow" out of it.
struct SettingsAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// In-app "hero" presentation of the settings panel.
///
/// Instead of opening a separate system window (which cannot be custom-animated),
/// the panel scales and fades out of the gear button's location with a spring,
/// dimming the rest of the window behind it.
@MainActor
struct SettingsHeroOverlay: View {
    @Environment(AppState.self) private var state

    /// Source button rect, in the overlay's coordinate space.
    let originRect: CGRect
    /// Size of the container the overlay fills.
    let containerSize: CGSize

    /// 读写 state.settingsOverlayShown（而非私有 @State）——EditorTabBar 的
    /// tab 条暗化需要跟这个真实动画状态完全同步，必须共享同一个值和同一处
    /// withAnimation 调用，否则两边动画时序错位。
    private var shown: Bool {
        get { state.settingsOverlayShown }
        nonmutating set { state.settingsOverlayShown = newValue }
    }

    private var anchorPoint: UnitPoint {
        guard containerSize.width > 0, containerSize.height > 0 else { return .center }
        return UnitPoint(
            x: max(0, min(1, originRect.midX / containerSize.width)),
            y: max(0, min(1, originRect.midY / containerSize.height))
        )
    }

    var body: some View {
        ZStack {
            // Dim backdrop — click to dismiss
            Rectangle()
                .fill(Color.black.opacity(shown ? 0.28 : 0))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            SettingsView(initialTab: state.settingsRequestedTab ?? .general,
                         embedded: true, onClose: { dismiss() })
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: DS.Stroke.regular)
                )
                .dsElevation(.hero)
                .scaleEffect(shown ? 1 : 0.18, anchor: anchorPoint)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            state.settingsRequestedTab = nil   // 深链一次性消费
            withAnimation(.spring(response: 0.42, dampingFraction: 0.80)) { shown = true }
        }
        .onExitCommand { dismiss() }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            state.showingSettings = false
        }
    }
}
