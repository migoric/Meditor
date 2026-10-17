import SwiftUI

// MARK: - Focus mode floating controls

/// Floating focus-mode toggle shown over the document in focus mode. Shares the
/// "focusToggle" matchedGeometry id with the toolbar's scope button so it flies
/// between the two positions (hero transition).
@MainActor
struct FocusToggleButton: View {
    @Environment(AppState.self) private var state
    @Bindable var workspaceUI: WorkspaceUIState
    @State private var isHovered = false
    @State private var breathe = false

    var body: some View {
        let theme = state.themeStore.current
        Button {
            withAnimation(DS.Motion.springFast) { workspaceUI.toggleFocusMode() }
        } label: {
            Image(systemName: "scope")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.appAccent)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .dsElevation(.floatingBar)
                )
                // Breathing accent halo — slow pulse that signals focus is active.
                .background(
                    Circle()
                        .fill(Color.appAccent)
                        .opacity(breathe ? 0.30 : 0.08)
                        .scaleEffect(breathe ? 1.55 : 1.08)
                        .blur(radius: 6)
                )
                .overlay(
                    Circle().strokeBorder(
                        Color.primary.opacity(isHovered ? 0.14 : 0.06), lineWidth: DS.Stroke.regular)
                )
                .scaleEffect(isHovered ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L("tooltip.exitFocus"))
        .animation(DS.Motion.micro, value: isHovered)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// 专注模式下鼠标移到顶部时浮现的退出按钮（Escape 已有快捷键，此处提供鼠标路径）。
@MainActor
struct FocusExitHoverZone: View {
    @Bindable var workspaceUI: WorkspaceUIState
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            workspaceUI.isFocusMode = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text(L("tooltip.exitFocus"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .dsElevation(.floatingBar)
                    }
                    .buttonStyle(.plain)
                    // 留出 macOS 流量灯宽度
                    .padding(.leading, 86)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isHovered)
    }
}

/// Transient hint surfaced when entering focus mode (Craft-style).
@MainActor
struct FocusHintToast: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let theme = state.themeStore.current
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .medium))
            Text(L("focus.hint"))
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(theme.craftSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .dsElevation(.floatingBar)
        )
    }
}
